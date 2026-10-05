#!/usr/bin/env python3
"""Simulated host for the ceb-gnrd BMC running in QEMU (run-qemu.sh).

--gui opens the control panel (run-qemu.sh starts it): a Tk window
(panel_tk.py) when there is a display, else a web page (panel.html,
http://localhost:8800; --web forces it).  It shows a drawing of the signals between the BMC and the host with their
LEDs and buttons, the fans, PSUs, temperatures, ADC inputs, POST codes and the
host serial console.  Without --gui it reads the commands below from stdin.

With the QEMU from build-qemu.sh the host lives inside QEMU (the bmc-host-sim
device, /machine/peripheral/host) and runs without this script; the script is
then only a console for it: it shows the host state and the BMC outputs and
sends the commands below.  With a stock QEMU it plays the host itself through
QEMU's QMP socket, using only what QEMU already emulates:

  BMC output                      simulated board reaction
  BMC_CPU_POWER_BUTTON (GPIOV2)   short pulse while off  -> power on: BMC_CPU_PWRGD
                                  (GPIOV4) high after 1 s, BMC_BIOS_BOOT_OK (GPIOM7)
                                  high after the POST time
                                  short pulse while on   -> OS shutdown: off after
                                  the shutdown time
                                  held >= 4 s while on   -> forced off at once
  BMC_CPU_RESET (GPIOV3)          pulse while on         -> BOOT_OK low, then high
                                  again after the POST time (PWRGD stays high)

  Inputs it drives for tests:     front panel power button (BMC_POWER_BUTTON_INPUT,
  GPIOM2), UID button (BMC_UID_BUTTON_N, GPIOV0), the four I2C temperature sensors.
  It reports the BMC's alert LED, UID LED, BIOS flash select and fan override
  outputs, and warns when the BMC takes the BIOS flash while the host is on.

Commands (type them while it runs; "help" lists them):
  status | power (front panel, 0.5 s) | power-hold (5 s) | uid
  hang on|off            BIOS never signals POST complete (alert LED boot timeout)
  powerfail              power good drops suddenly
  temp <name|all> <C>    names: inlet outlet pcie m2
  fan <0-5|all> <rpm|auto>  fixed fan speed, or back to following the PWM duty
  fan max <rpm>          fan speed at 100% PWM (needs the QEMU from build-qemu.sh)
  The patched QEMU only:
  psu <0-2> in|out       insert or pull a PSU module (slot 2 starts empty)
  psu <0-2> ac on|off    AC input present or lost
  psu <0-2> load <W>     output power
  psu <0-2> temp <C>     PSU hotspot temperature
  cpu <C> | dimm <C>     CPU package / DIMM temperature over PECI
  adc <0-15> <V>         measured rail voltage; divider applied automatically
  rtc battery ok|low     RTC battery (low: the RTC time is refused)
  post <s> | shutdown <s>
  quit

Usage: host-sim.py [--gui [--port 8800]] [--qmp ~/qemu-ceb-gnrd/qmp.sock]
                   [--uart ~/qemu-ceb-gnrd/host-uart.sock] [--post 20] [--shutdown 10]
Python 3 standard library only.
"""

import argparse
import collections
import http.server
import json
import math
import os
import shlex
import socket
import struct
import sys
import threading
import time
import uuid
from pathlib import Path
from host_io import HostIO, USBHost, ESPI, VHUB
from panel_services import PanelServices, VIDEO, JPEG_LIMIT, validate_jpeg

GPIO = "/machine/soc/gpio"
# BMC outputs
POWER_OUT = "gpioV2"      # BMC_CPU_POWER_BUTTON, active low
RESET_OUT = "gpioV3"      # BMC_CPU_RESET, active low
ALERT_LED = "gpioI5"      # BMC_SYS_ALERT_LED
UID_LED = "gpioV1"        # BMC_UID_LED
FLASH_SEL = "gpioM1"      # BMC_BIOS_FLASH_SELECT, high = BMC owns the BIOS flash
FAN_OVERRIDE = "gpioI6"   # BMC_FAN_BMC_OVERRIDE_N, high = BMC drives the fans
# BMC inputs (driven by the simulated board)
PWRGD = "gpioV4"          # BMC_CPU_PWRGD
BOOT_OK = "gpioM7"        # BMC_BIOS_BOOT_OK
PWR_BTN_IN = "gpioM2"     # BMC_POWER_BUTTON_INPUT, active low (front panel)
UID_BTN = "gpioV0"        # BMC_UID_BUTTON_N, active low

PWM = "/machine/soc/pwm"
FANS = 6                  # SYS_FAN0..5 on PWM/TACH channels 0..5
PECI = "/machine/soc/peci"
ADC = "/machine/soc/adc"
PSU = "/machine/peripheral/psu%d"
RTC = "/machine/peripheral/rtc"
CHASSIS = "/machine/soc/chassis"
HOST_IO = None
USB = None
SERVICES = None

TEMPS = {
    "inlet": ("/machine/peripheral/temp-inlet", 25.0),
    "outlet": ("/machine/peripheral/temp-outlet", 35.0),
    "pcie": ("/machine/peripheral/temp-pcie", 40.0),
    "m2": ("/machine/peripheral/temp-m2", 38.0),
}
WATCHED = {ALERT_LED: "alert LED", UID_LED: "UID LED",
           FLASH_SEL: "BIOS flash select (1 = BMC)",
           FAN_OVERRIDE: "fan override (1 = BMC)"}
# Low-active BMC outputs with a board pull-up: high while the BMC has not driven them
PULLED_UP = (POWER_OUT, RESET_OUT)
# BMC outputs that keep their level while the BMC resets (GPIO reset tolerance)
RETAINED = {POWER_OUT: "power button out", RESET_OUT: "reset out",
            FLASH_SEL: "BIOS flash select"}
BMC_BOOT_MAX_S = 240      # give up waiting for the BMC to drive the pins again
HOST_DEV = "/machine/peripheral/host"   # bmc-host-sim in the patched QEMU
FORCE_OFF_S = 4.0
POLL_S = 0.05
LPC = "/machine/soc/lpc"
ADC_NAMES = ["P12V_SYS", "P5V0_SYS", "P3V3_SYS", "PVCCIN_CPU", "PVNN_NAC_CPU",
             "PVCCD0_HV_CPU", "PVCCINF_CPU", "PVNN_MAIN_CPU", "PVCCFA_EHV_CPU",
             "PVCCD1_HV_CPU", "PVCCINF_EHV_FIVRA_CPU", "P3V3_STBY", "P1V8_STBY",
             "P1V2_STBY", "P1V0_STBY", "D3V0_BAT0"]
ADC_NOMINAL_MV = [1091, 455, 1650, 1800, 900, 1130, 850, 1000, 1800, 1130, 1800,
                  1650, 1800, 1200, 1000, 3000]
ADC_SCALE = [11, 11, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1]

LOG = collections.deque(maxlen=300)     # recent log lines, for the panel


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    LOG.append(line)
    print(line, flush=True)


class Qmp:
    def __init__(self, path):
        deadline = time.time() + 60
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    sys.exit("cannot connect to QMP socket %s (is run-qemu.sh running?)" % path)
                time.sleep(1)
        self.file = self.sock.makefile("rwb")
        self.lock = threading.Lock()
        self.resets = 0                                # QEMU RESET events seen
        self._read()                                   # greeting
        self.execute("qmp_capabilities")

    def _read(self):
        line = self.file.readline()
        if not line:
            print("QEMU closed the QMP connection", flush=True)
            os._exit(0)
        return json.loads(line)

    def execute(self, command, **arguments):
        with self.lock:
            msg = {"execute": command}
            if arguments:
                msg["arguments"] = arguments
            self.file.write(json.dumps(msg).encode() + b"\n")
            self.file.flush()
            while True:
                reply = self._read()
                if "return" in reply:
                    return reply["return"]
                if "error" in reply:
                    raise RuntimeError("%s: %s" % (command, reply["error"].get("desc")))
                # asynchronous event: only a machine reset (BMC reboot or watchdog
                # reset) matters here
                if reply.get("event") == "RESET":
                    self.resets += 1

    def get(self, pin):
        return bool(self.execute("qom-get", path=GPIO, property=pin))

    def set(self, pin, value):
        self.execute("qom-set", path=GPIO, property=pin, value=bool(value))

    def set_temp(self, path, celsius):
        self.execute("qom-set", path=path, property="temperature",
                     value=int(celsius * 1000))


class Host:
    def __init__(self, qmp, post_s, shutdown_s):
        self.q = qmp
        self.post_s = post_s
        self.shutdown_s = shutdown_s
        self.hang = False
        self.state = "off"           # off, starting, post, on, shutting-down
        self.deadline = None         # time of the next automatic step
        self.power_low_since = None
        self.reset_low = False
        self.forced = False
        self.outputs = {}
        self.lock = threading.Lock()
        self.seen_resets = qmp.resets
        self.bmc_reset_at = None     # time of the BMC reset being waited out
        self.held = {}               # pin levels kept across that reset
        self.prev = {}               # last level seen of the pins in RETAINED

    # --- BMC reset -------------------------------------------------------------
    # On the board the BMC pins below keep their level while the BMC resets (the
    # AST2600 GPIO reset tolerance, which the kernel enables for every line that
    # user space requests; see the GPIO table in quick-start.md).  QEMU resets
    # its whole GPIO model instead, so the pins read low: BMC_CPU_RESET low would
    # look like a host reset and BMC_CPU_POWER_BUTTON low for 4 s like a forced
    # power off.  After a QEMU reset the last levels are therefore held until the
    # BMC has driven both power pins high again (x86-power-control after boot).
    # BMC_FAN_BMC_OVERRIDE_N is deliberately not retained (the fans go back to
    # the CPLD, see ceb-gnrd-fan-owner).
    def pin(self, pin):
        value = self.q.get(pin)
        if self.q.resets != self.seen_resets:
            self.seen_resets = self.q.resets
            self.bmc_reset_at = time.time()
            self.held = dict(self.prev)
            log("BMC reset: holding %s at their last levels until the BMC drives "
                "the power pins again" % ", ".join(
                    sorted(RETAINED[p] for p in self.held)))
        if self.bmc_reset_at is not None and pin in self.held:
            return self.held[pin]
        if pin in RETAINED:
            self.prev[pin] = value
        return value

    def check_bmc_back(self):
        if self.bmc_reset_at is None:
            return
        power, reset = self.q.get(POWER_OUT), self.q.get(RESET_OUT)
        if (power and reset) or time.time() - self.bmc_reset_at > BMC_BOOT_MAX_S:
            log("BMC reset: the BMC drives the power pins again (%.0f s)"
                % (time.time() - self.bmc_reset_at))
            self.bmc_reset_at = None
            self.held = {}

    # --- board outputs -------------------------------------------------------
    def set_power(self, pwrgd, boot_ok):
        self.q.set(PWRGD, pwrgd)
        self.q.set(BOOT_OK, boot_ok)

    def go(self, state, delay=None):
        self.state = state
        self.deadline = time.time() + delay if delay is not None else None
        log("host: %s" % state)

    def power_on(self, why):
        if self.state != "off":
            return
        log("host: power on (%s)" % why)
        self.go("starting", 1.0)

    def power_off(self, why):
        log("host: power off (%s)" % why)
        self.set_power(False, False)
        self.go("off")

    def start_post(self):
        self.q.set(BOOT_OK, False)
        if self.hang:
            log("host: POST started, BIOS hang simulated: BOOT_OK stays low")
            self.go("post")
        else:
            self.go("post", self.post_s)

    # --- reactions to the BMC ------------------------------------------------
    def on_power_button(self, held_s):
        if self.state == "off":
            self.power_on("power button pulse %.1f s" % held_s)
        elif self.state in ("starting", "post", "on"):
            log("host: power button pulse %.1f s: OS shutdown in %d s"
                % (held_s, self.shutdown_s))
            self.go("shutting-down", self.shutdown_s)

    def step(self):
        with self.lock:
            now = time.time()
            power_low = not self.pin(POWER_OUT)
            if power_low and self.power_low_since is None:
                self.power_low_since = now
                self.forced = False
            if power_low and not self.forced and self.state != "off" \
                    and now - self.power_low_since >= FORCE_OFF_S:
                self.forced = True
                self.power_off("power button held %.0f s" % FORCE_OFF_S)
            if not power_low and self.power_low_since is not None:
                held = now - self.power_low_since
                self.power_low_since = None
                if not self.forced:
                    self.on_power_button(held)

            reset_low = not self.pin(RESET_OUT)
            if reset_low and not self.reset_low and self.state in ("post", "on"):
                log("host: reset asserted")
                self.q.set(BOOT_OK, False)
            if not reset_low and self.reset_low and self.state in ("post", "on"):
                log("host: reset released, POST again")
                self.start_post()
            self.reset_low = reset_low

            if self.deadline is not None and now >= self.deadline:
                self.deadline = None
                if self.state == "starting":
                    self.q.set(PWRGD, True)
                    log("host: PWRGD high")
                    self.start_post()
                elif self.state == "post":
                    self.q.set(BOOT_OK, True)
                    log("host: BOOT_OK high (POST complete)")
                    self.go("on")
                elif self.state == "shutting-down":
                    self.power_off("OS shut down")

            for pin, name in WATCHED.items():
                value = self.pin(pin)
                if self.outputs.get(pin) != value:
                    if pin in self.outputs:
                        log("BMC: %s -> %d" % (name, value))
                    self.outputs[pin] = value
                    if pin == FLASH_SEL and value and self.state != "off":
                        log("WARNING: the BMC took the BIOS flash while the host is %s"
                            % self.state)
            self.check_bmc_back()

    # --- test inputs ---------------------------------------------------------
    def press(self, pin, seconds, name):
        log("press %s for %.1f s" % (name, seconds))
        self.q.set(pin, False)
        time.sleep(seconds)
        self.q.set(pin, True)

    def front_panel_power(self, seconds):
        # The real button also reaches the PCH through the CPLD; the BMC only
        # sees a copy (BMC_POWER_BUTTON_INPUT).
        self.press(PWR_BTN_IN, seconds, "front panel power button")
        with self.lock:
            if seconds >= FORCE_OFF_S and self.state != "off":
                self.power_off("front panel button held")
            elif seconds < FORCE_OFF_S:
                if self.state == "off":
                    self.power_on("front panel button")
                else:
                    self.go("shutting-down", self.shutdown_s)

    def set_hang(self, on):
        self.hang = on

    def power_fail(self):
        with self.lock:
            self.power_off("power failure")

    def set_times(self):
        pass

    def status(self):
        with self.lock:
            pins = {name: int(self.q.get(pin)) for pin, name in
                    [(PWRGD, "PWRGD"), (BOOT_OK, "BOOT_OK"), (POWER_OUT, "power out"),
                     (RESET_OUT, "reset out")] + list(WATCHED.items())}
        temps = {}
        for name, (path, _) in TEMPS.items():
            try:
                temps[name] = self.q.execute("qom-get", path=path,
                                             property="temperature") / 1000
            except RuntimeError:
                temps[name] = None
        log("host state: %s%s" % (self.state, " (BIOS hang)" if self.hang else ""))
        log("GPIO: " + ", ".join("%s=%s" % kv for kv in pins.items()))
        log("temperatures: " + ", ".join("%s=%s" % kv for kv in temps.items()))


class BuiltinHost(Host):
    """Console for the bmc-host-sim device: QEMU runs the host."""

    def __init__(self, qmp, post_s, shutdown_s):
        super().__init__(qmp, post_s, shutdown_s)
        self.state = self.prop("state")
        qmp.execute("qom-set", path=HOST_DEV, property="post-ms", value=int(post_s * 1000))
        qmp.execute("qom-set", path=HOST_DEV, property="shutdown-ms",
                    value=int(shutdown_s * 1000))

    def prop(self, name):
        return self.q.execute("qom-get", path=HOST_DEV, property=name)

    def set_prop(self, name, value):
        self.q.execute("qom-set", path=HOST_DEV, property=name, value=value)

    def step(self):
        with self.lock:
            state = self.prop("state")
            if state != self.state:
                self.state = state
                log("host: %s" % state)
            for pin, name in WATCHED.items():
                value = self.q.get(pin)
                if self.outputs.get(pin) != value:
                    if pin in self.outputs:
                        log("BMC: %s -> %d" % (name, value))
                    self.outputs[pin] = value
                    if pin == FLASH_SEL and value and state != "off":
                        log("WARNING: the BMC took the BIOS flash while the host is %s"
                            % state)

    def front_panel_power(self, seconds):
        log("press front panel power button for %.1f s" % seconds)
        self.set_prop("press-power-button", int(seconds * 1000))

    def press(self, pin, seconds, name):
        log("press %s for %.1f s" % (name, seconds))
        self.set_prop("press-uid-button", int(seconds * 1000))

    def set_hang(self, on):
        self.hang = on
        self.set_prop("hang", on)

    def power_fail(self):
        self.set_prop("power-fail", True)

    def set_times(self):
        self.set_prop("post-ms", int(self.post_s * 1000))
        self.set_prop("shutdown-ms", int(self.shutdown_s * 1000))


HELP = ("commands: status | power | power-hold | uid | hang on|off | "
        "powerfail | temp <inlet|outlet|pcie|m2|all> <C> | "
        "fan <0-5|all> <rpm|auto> | fan max <rpm> | "
        "psu <0-2> in|out|ac on|off|load <W>|temp <C> | cpu <C> | "
        "dimm <C> | adc <0-15> <V> | rtc battery ok|low | postcode <hex> | "
        "chassis open|closed | espi reset assert|release | espi vw <mask> <value> | "
        "espi error <mask> | ipmi <hex bytes> | usb reconnect | usb media <port> | "
        "vga <JPEG path>|auto | "
        "post <s> | shutdown <s> | quit")


def run_command(host, qmp, words):
    """One command, typed or sent by the panel.  Raises on bad input."""
    if not words:
        raise ValueError("请输入命令")
    cmd, rest = words[0], words[1:]
    if cmd == "status":
        host.status()
    elif cmd == "power":
        threading.Thread(target=host.front_panel_power, args=(0.5,), daemon=True).start()
    elif cmd == "power-hold":
        threading.Thread(target=host.front_panel_power, args=(5.0,), daemon=True).start()
    elif cmd == "uid":
        threading.Thread(target=host.press, args=(UID_BTN, 0.5, "UID button"),
                         daemon=True).start()
    elif cmd == "hang" and rest and rest[0] in ("on", "off"):
        host.set_hang(rest[0] == "on")
        log("BIOS hang %s (applies to the next POST)" % rest[0])
    elif cmd == "powerfail":
        host.power_fail()
    elif cmd == "temp" and len(rest) == 2:
        names = list(TEMPS) if rest[0] == "all" else [rest[0]]
        for name in names:
            qmp.set_temp(TEMPS[name][0], float(rest[1]))
        log("temperature %s = %s C" % (rest[0], rest[1]))
    elif cmd == "fan" and len(rest) == 2:
        if rest[0] == "max":
            qmp.execute("qom-set", path=PWM, property="fan-max-rpm", value=int(rest[1]))
        else:
            rpm = -1 if rest[1] == "auto" else int(rest[1])
            fans = range(FANS) if rest[0] == "all" else [int(rest[0])]
            for fan in fans:
                qmp.execute("qom-set", path=PWM, property="fan%d-rpm" % fan, value=rpm)
        log("fan %s = %s" % (rest[0], rest[1]))
    elif cmd == "psu" and len(rest) >= 2:
        path = PSU % int(rest[0])
        if rest[1] in ("in", "out"):
            qmp.execute("qom-set", path=path, property="present", value=rest[1] == "in")
        elif rest[1] == "ac" and len(rest) == 3:
            qmp.execute("qom-set", path=path, property="ac-lost", value=rest[2] == "off")
        elif rest[1] == "load" and len(rest) == 3:
            qmp.execute("qom-set", path=path, property="pout-mw",
                        value=int(float(rest[2]) * 1000))
        elif rest[1] == "temp" and len(rest) == 3:
            qmp.execute("qom-set", path=path, property="temp2-mc",
                        value=int(float(rest[2]) * 1000))
        else:
            raise ValueError("psu <0-2> in|out | ac on|off | load <W> | temp <C>")
        log("PSU %s: %s" % (rest[0], " ".join(rest[1:])))
    elif cmd in ("cpu", "dimm") and len(rest) == 1:
        qmp.execute("qom-set", path=PECI, property="%s-temp-mc" % cmd,
                    value=int(float(rest[0]) * 1000))
        log("%s temperature = %s C" % (cmd.upper(), rest[0]))
    elif cmd == "adc" and len(rest) == 2:
        channel = int(rest[0])
        rail = float(rest[1].rstrip("Vv"))
        if not 0 <= channel < 16 or not math.isfinite(rail) or not 0 <= rail <= 100:
            raise ValueError("ADC 通道 0..15，电源轨电压 0..100 V")
        pad_mv = round(rail * 1000 / ADC_SCALE[channel])
        qmp.execute("qom-set", path=ADC, property="ch%d-mv" % channel, value=pad_mv)
        log("%s = %.3f V；分压 ÷%s，ADC 引脚 %.3f V%s" % (
            ADC_NAMES[channel], rail, ADC_SCALE[channel], pad_mv / 1000,
            "（超过 2.5 V，ADC 读数将饱和）" if pad_mv > 2500 else ""))
    elif cmd == "rtc" and len(rest) == 2 and rest[0] == "battery":
        qmp.execute("qom-set", path=RTC, property="battery-ok", value=rest[1] == "ok")
        log("RTC battery %s" % rest[1])
    elif cmd == "postcode" and len(rest) == 1:
        code = int(rest[0], 16)
        if not 0 <= code <= 255:
            raise ValueError("POST 码范围 00..FF")
        if HOST_IO:
            HOST_IO.write(0x80, code)
        else:
            qmp.execute("qom-set", path=LPC, property="post-code", value=code)
        log("POST code 0x%02x written to port 80h" % int(rest[0], 16))
    elif cmd == "chassis" and rest in (["open"], ["closed"]):
        qmp.execute("qom-set", path=CHASSIS, property="open", value=rest[0] == "open")
        log("CHASI#：" + ("开盖" if rest[0] == "open" else "合盖；告警锁存由 BMC 清除"))
    elif cmd == "espi" and HOST_IO:
        if len(rest) == 3 and rest[:2] == ["reset", "assert"]:
            raise ValueError("espi reset assert|release")
        if len(rest) == 2 and rest[0] == "reset" and rest[1] in ("assert", "release"):
            HOST_IO.set(ESPI, "host-reset", rest[1] == "assert")
        elif len(rest) == 3 and rest[0] == "vw":
            HOST_IO.set(ESPI, "host-vw", " ".join(rest[1:]))
        elif len(rest) == 2 and rest[0] == "error":
            HOST_IO.set(ESPI, "inject-error", rest[1])
        else:
            raise ValueError("espi reset assert|release / vw MASK VALUE / error MASK")
        log("eSPI: " + " ".join(rest))
    elif cmd == "ipmi" and rest and HOST_IO:
        request = bytes.fromhex(" ".join(rest))
        response = HOST_IO.ipmi(request)
        log("KCS IPMI 响应：" + response.hex(" "))
    elif cmd == "usb" and USB:
        if rest == ["reconnect"]:
            USB.set_connected(False)
            # The worker reconnects only while the host is powered.
            log("USB 已断开，等待主机侧重新枚举")
        elif len(rest) == 2 and rest[0] == "media":
            result = USB.media_probe(int(rest[1]))
            log("USB 媒体读取：" + json.dumps(result, ensure_ascii=False))
        else:
            raise ValueError("usb reconnect / usb media PORT")
    elif cmd == "vga" and SERVICES:
        if rest == ["auto"]:
            SERVICES.auto_vga()
        elif rest in (["on"], ["off"]):
            SERVICES.set_signal(rest[0] == "on")
        elif len(rest) == 1:
            SERVICES.set_vga(rest[0])
        else:
            raise ValueError("vga <JPEG path>|auto|on|off")
    elif cmd == "post" and rest:
        host.post_s = float(rest[0])
        host.set_times()
        log("POST time %s s" % rest[0])
    elif cmd == "shutdown" and rest:
        host.shutdown_s = float(rest[0])
        host.set_times()
        log("OS shutdown time %s s" % rest[0])
    else:
        raise ValueError(HELP)


VIDEO = "/machine/soc/video-engine"
KVM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kvm")
SCREENS = {"post": "post.jpg", "on": "os.jpg", "shutting-down": "os.jpg"}


def set_screen(qmp, state):
    """The host's VGA output the BMC KVM shows: no signal while the host is
    off, a BIOS screen during POST, the OS console when it runs."""
    name = SCREENS.get(state)
    with SERVICES.lock:
        if SERVICES.vga_override:
            qmp.execute("qom-set", path=VIDEO, property="image", value=SERVICES.vga_override)
        elif name:
            qmp.execute("qom-set", path=VIDEO, property="image",
                        value=os.path.join(KVM_DIR, name))
        signal = bool(name) if SERVICES.vga_signal is None else SERVICES.vga_signal
        qmp.execute("qom-set", path=VIDEO, property="signal", value=signal)


# BMC outputs as the board sees them: the level the BMC drives, or the board's
# pull-up/down while the pin is not an output (BMC booting, line not requested).
BOARD_PULL = {POWER_OUT: True, RESET_OUT: True, ALERT_LED: False, UID_LED: False,
              FLASH_SEL: False, FAN_OVERRIDE: False}


def board_level(qmp, pin):
    index = ord(pin[4]) - ord("A")              # "gpioV2": group V, pin 2
    bit = (index % 4) * 8 + int(pin[5:])
    direction = qom(qmp, GPIO, "gpio-dir[%d]" % (index // 4))
    if direction is not None and not direction >> bit & 1:
        return BOARD_PULL[pin]
    return qmp.get(pin)


def qom(qmp, path, prop):
    """A property, or None when this QEMU does not have it."""
    try:
        return qmp.execute("qom-get", path=path, property=prop)
    except RuntimeError:
        return None


class HostConsole:
    """The host's end of its serial port (VUART, or UART3 with a stock QEMU).

    It shows what the BMC sends (SOL input), and plays a minimal host: boot
    messages when the host powers on and a shell that echoes what it gets.
    """

    def __init__(self, path):
        self.path = path
        self.sock = None
        self.text = ""          # what crossed the port, for the panel
        self.offset = 0         # characters dropped from the front of text
        self.line = ""
        self.lock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def _add(self, text):
        with self.lock:
            self.text += text
            if len(self.text) > 65536:
                cut = len(self.text) - 49152
                self.text = self.text[cut:]
                self.offset += cut

    def _reader(self):
        while True:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self.path)
            except OSError:
                time.sleep(1)
                continue
            self.sock = sock
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                text = data.decode("utf-8", "replace")
                self._add(text)
                self._shell(text)
            self.sock = None

    def send(self, text):
        """The host writes text to its serial port (the BMC receives it)."""
        text = text.replace("\r\n", "\n").replace("\n", "\r\n")
        self._add(text)
        if self.sock:
            try:
                self.sock.sendall(text.encode())
            except OSError:
                pass

    def _shell(self, text):
        # a host that runs an OS echoes what it is sent, and answers Enter with
        # a prompt; while it is off, the BMC talks to nobody
        if host_state() != "on":
            return
        for ch in text:
            if ch in "\r\n":
                self.send("\n[root@ceb-gnrd-host ~]# ")
                self.line = ""
            else:
                self.line += ch
                self.send(ch)

    def on_state(self, old, new):
        if new == "post":
            self.send("\n\nIntel(R) Xeon(R) 6 SoC (simulated)  BIOS POST\n"
                      "Memory test ... OK\nPCIe enumeration ... OK\n")
        elif new == "on":
            self.send("Booting the OS ...\n\nceb-gnrd-host login: root (automatic login)\n"
                      "[root@ceb-gnrd-host ~]# ")
        elif new == "shutting-down":
            self.send("\nThe system is going down for power off NOW!\n")
        elif new == "off" and old != "off":
            self.send("reboot: Power down\n")

    def since(self, pos):
        with self.lock:
            start = max(pos - self.offset, 0)
            return self.offset + len(self.text), self.text[start:]


class ESPIConsole(HostConsole):
    """Host COM1 bytes routed through Peripheral I/O, with ready checks."""
    def __init__(self, io):
        self.io = io
        self.pending = bytearray()
        self.tx_lock = threading.Lock()
        super().__init__(None)

    def send(self, text):
        text = text.replace("\r\n", "\n").replace("\n", "\r\n")
        self._add(text)
        if host_state() != "off":
            with self.tx_lock:
                if len(self.pending) + len(text.encode()) > 65536:
                    raise ValueError("主机串口待发送缓冲已满；检查 eSPI 就绪状态")
                self.pending.extend(text.encode())

    def _reader(self):
        while True:
            try:
                if host_state() == "off":
                    with self.tx_lock:
                        self.pending.clear()
                elif self.io.get(ESPI, "peripheral-ready"):
                    received = bytearray()
                    for _ in range(32):
                        lsr = self.io.read(0x3fd)
                        if lsr & 1:
                            received.append(self.io.read(0x3f8))
                        with self.tx_lock:
                            if self.pending and lsr & 0x20:
                                self.io.write(0x3f8, self.pending[0])
                                del self.pending[0]
                        if not lsr & 1 and not self.pending:
                            break
                    if received:
                        text = received.decode("utf-8", "replace")
                        self._add(text)
                        self._shell(text)
            except RuntimeError:
                pass  # firmware has not enabled VUART, or channel reset
            time.sleep(0.02)


HOST = None             # the Host in use, for host_state()


def host_state():
    return HOST.state if HOST else "off"


class Panel:
    """State of the simulated board, polled from QEMU for the panel."""

    def __init__(self, host, qmp, console):
        self.host = host
        self.q = qmp
        self.console = console
        self.state = {}
        self.posts = collections.deque(maxlen=64)
        self.last_post = None
        self.last_host = host.state
        # Board pull-ups: the BMC's low-active outputs (power button, reset) are
        # inputs, and so high, until the BMC drives them after it has booted
        # (x86-power-control); QEMU's GPIO model reads 0 for them instead.  Show
        # them high until they have been seen high once since the last reset.
        self.undriven = set(PULLED_UP)
        self.seen_resets = qmp.resets
        self._prev = None
        threading.Thread(target=self._poller, daemon=True).start()

    def _poller(self):
        while True:
            try:
                self.state = self.collect()
            except RuntimeError as exc:
                log("QMP error: %s" % exc)
            time.sleep(0.4)

    def collect(self):
        q = self.q
        st = {"host": self.host.state, "hang": self.host.hang,
              "builtin": isinstance(self.host, BuiltinHost)}
        if st["host"] != self.last_host:
            if self.console:
                self.console.on_state(self.last_host, st["host"])
            self.last_host = st["host"]
        st["pins"] = {pin: q.get(pin) for pin in
                      (PWRGD, BOOT_OK, PWR_BTN_IN, UID_BTN)}
        st["pins"].update({pin: board_level(q, pin) for pin in BOARD_PULL})
        if q.resets != self.seen_resets:
            self.seen_resets = q.resets
            self.undriven = set(PULLED_UP)
        for pin in list(self.undriven):
            if st["pins"][pin]:
                self.undriven.discard(pin)       # the BMC drives it high now
            else:
                st["pins"][pin] = True           # board pull-up
        st["temps"] = {name: (qom(q, path, "temperature") or 0) / 1000
                       for name, (path, _) in TEMPS.items()}
        st["fans"] = []
        for i in range(FANS):
            st["fans"].append({"rpm": qom(q, PWM, "fan%d-speed" % i),
                               "duty": qom(q, PWM, "pwm%d-duty" % i),
                               "fixed": qom(q, PWM, "fan%d-rpm" % i)})
        st["fan_max"] = qom(q, PWM, "fan-max-rpm")
        st["psus"] = []
        for i in range(3):
            path = PSU % i
            psu = {k: qom(q, path, k) for k in
                   ("present", "ac-lost", "vin-mv", "vout-mv", "pout-mw",
                    "efficiency", "temp2-mc", "fan-rpm")}
            psu["model"] = "crps" if psu["present"] is not None else (
                "basic" if qom(q, path, "type") is not None else None)
            st["psus"].append(psu)
        st["peci"] = {k: qom(q, PECI, k) for k in
                      ("cpu-online", "cpu-temp-mc", "dimm-temp-mc", "tjmax")}
        st["adc"] = [{"name": ADC_NAMES[i], "scale": ADC_SCALE[i],
                      "mv": qom(q, ADC, "ch%d-mv" % i)} for i in range(16)]
        st["rtc_battery"] = qom(q, RTC, "battery-ok")
        st["chassis"] = {"open": qom(q, CHASSIS, "open"), "latched": qom(q, CHASSIS, "latched")}
        st["espi"] = {k: qom(q, ESPI, k) for k in
                      ("host-reset", "peripheral-ready", "vw-ready", "boot-ready", "host-irq4")}
        st["usb"] = USB.state if USB else {"available": False}
        st["video"] = SERVICES.state()
        st["video"]["available"] = qom(q, VIDEO, "signal") is not None
        st["video"]["signal"] = qom(q, VIDEO, "signal")
        st["video"]["path"] = qom(q, VIDEO, "image")
        code = qom(q, LPC, "post-code")
        if code is not None and code != self.last_post:
            self.last_post = code
            self.posts.append((time.strftime("%H:%M:%S"), code))
        st["post"] = code
        st["posts"] = list(self.posts)
        self._log_changes(st)
        st["log"] = list(LOG)[-200:]
        return st

    # --- event log: what changed on the board since the last poll -------------
    PIN_LOG = {
        POWER_OUT: ("GPIOV2 BMC_CPU_POWER_BUTTON", "BMC→主机", True),
        RESET_OUT: ("GPIOV3 BMC_CPU_RESET", "BMC→主机", True),
        FLASH_SEL: ("GPIOM1 BMC_BIOS_FLASH_SELECT", "BMC→主机", False),
        FAN_OVERRIDE: ("GPIOI6 BMC_FAN_BMC_OVERRIDE_N", "BMC→主机", False),
        ALERT_LED: ("GPIOI5 BMC_SYS_ALERT_LED", "BMC→主机", False),
        UID_LED: ("GPIOV1 BMC_UID_LED", "BMC→主机", False),
        PWRGD: ("GPIOV4 BMC_CPU_PWRGD", "主机→BMC", False),
        BOOT_OK: ("GPIOM7 BMC_BIOS_BOOT_OK", "主机→BMC", False),
        PWR_BTN_IN: ("GPIOM2 BMC_POWER_BUTTON_INPUT", "主机→BMC", True),
        UID_BTN: ("GPIOV0 BMC_UID_BUTTON_N", "主机→BMC", True),
    }

    def _log_changes(self, st):
        prev, self._prev = getattr(self, "_prev", None), st
        if prev is None:
            return          # first poll: nothing to compare with

        def fmt(v):
            return "-" if v is None else v

        for pin, (name, direction, low_active) in self.PIN_LOG.items():
            if pin in WATCHED:
                continue    # the host model logs these ("BMC: alert LED -> 1")
            old, new = prev["pins"].get(pin), st["pins"].get(pin)
            if old is not None and new is not None and old != new:
                note = ""
                if low_active:
                    note = "（低有效，已动作）" if not new else "（低有效，已释放）"
                log("信号 %s [%s] %d→%d%s" % (name, direction, old, new, note))
        for name, new in st["temps"].items():
            old = prev["temps"].get(name)
            if old is not None and abs(new - old) >= 0.5:
                log("温度传感器 %s：%.1f→%.1f °C" % (name, old, new))
        for i, (a, b) in enumerate(zip(prev["fans"], st["fans"])):
            if a.get("fixed") != b.get("fixed"):
                fixed = b.get("fixed")
                log("SYS_FAN%d %s" % (i, "恢复为跟随 PWM" if fixed in (None, -1)
                                     else ("故障（0 RPM）" if fixed == 0
                                           else "固定转速 %s RPM" % fixed)))
            ra, rb = a.get("rpm"), b.get("rpm")
            if ra is not None and rb is not None and abs(rb - ra) >= max(300, ra // 10):
                log("SYS_FAN%d 转速 %s→%s RPM（PWM %s%%）" % (i, ra, rb, fmt(b.get("duty"))))
        for i, (a, b) in enumerate(zip(prev["psus"], st["psus"])):
            if b.get("model") != "crps":
                continue
            if a.get("present") != b.get("present"):
                log("PSU%d %s" % (i, "插入" if b["present"] else "拔出"))
            if a.get("ac-lost") != b.get("ac-lost"):
                log("PSU%d AC %s" % (i, "掉电" if b["ac-lost"] else "恢复"))
            if abs((a.get("pout-mw") or 0) - (b.get("pout-mw") or 0)) >= 10000:
                log("PSU%d 输出功率 %.0f→%.0f W" % (i, (a.get("pout-mw") or 0) / 1000,
                                                  (b.get("pout-mw") or 0) / 1000))
            if abs((a.get("temp2-mc") or 0) - (b.get("temp2-mc") or 0)) >= 1000:
                log("PSU%d 温度 %.0f→%.0f °C" % (i, (a.get("temp2-mc") or 0) / 1000,
                                                (b.get("temp2-mc") or 0) / 1000))
        pa, pb = prev["peci"], st["peci"]
        if pa.get("cpu-online") != pb.get("cpu-online") and pb.get("cpu-online") is not None:
            log("PECI CPU %s" % ("上线" if pb["cpu-online"] else "无响应"))
        for key, label in (("cpu-temp-mc", "CPU"), ("dimm-temp-mc", "DIMM")):
            if pa.get(key) is not None and pb.get(key) is not None                     and abs(pa[key] - pb[key]) >= 1000:
                log("PECI %s 温度 %.0f→%.0f °C" % (label, pa[key] / 1000, pb[key] / 1000))
        for i, (a, b) in enumerate(zip(prev["adc"], st["adc"])):
            if a.get("mv") != b.get("mv") and b.get("mv") is not None:
                log("ADC%d %s：ADC 引脚 %s→%s mV（电源轨 %.3f V）" % (
                    i, b["name"], fmt(a.get("mv")), b["mv"], b["mv"] * b["scale"] / 1000))
        if prev["rtc_battery"] != st["rtc_battery"] and st["rtc_battery"] is not None:
            log("RTC 电池 %s" % ("正常" if st["rtc_battery"] else "没电"))
        for key, label in (("open", "机箱开盖"), ("latched", "入侵锁存")):
            if prev["chassis"].get(key) != st["chassis"].get(key) and st["chassis"].get(key) is not None:
                log("%s：%s" % (label, "是" if st["chassis"][key] else "否"))
        for key in st["espi"]:
            a, b = prev["espi"].get(key), st["espi"].get(key)
            if a != b and b is not None:
                log("eSPI %s：%s→%s" % (key, fmt(a), b))
        ua, ub = prev["usb"], st["usb"]
        if ua.get("connected") != ub.get("connected") and ub.get("connected") is not None:
            log("USB 主机侧：%s" % ("已连接" if ub["connected"] else "未连接"))
        old_reports = len(ua.get("reports", []))
        for r in ub.get("reports", [])[old_reports:][:5]:
            log("USB HID 报告 port%s ep%s %s" % (r["port"], r["endpoint"], r["hex"]))
        va, vb = prev["video"], st["video"]
        if va.get("signal") != vb.get("signal") and vb.get("signal") is not None:
            log("VGA 输入：%s" % ("有信号" if vb["signal"] else "无信号"))
        if va.get("path") != vb.get("path") and vb.get("path"):
            log("VGA 图片：%s" % os.path.basename(vb["path"]))
        if st["post"] is not None and prev["post"] != st["post"]:
            log("POST 码 0x%02X（端口 80h）" % st["post"])


def serve_panel(panel, port, host, qmp):
    html = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "panel.html"), "rb").read()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def reply(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self.reply(200, html, "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self.reply(200, panel.state)
            elif self.path.startswith("/api/vga"):
                path = qom(qmp, VIDEO, "image")
                try:
                    self.reply(200, validate_jpeg(path), "image/jpeg")
                except (OSError, ValueError, TypeError):
                    self.reply(404, {"error": "暂无 VGA 图片"})
            elif self.path.startswith("/api/console"):
                pos = int(self.path.partition("pos=")[2] or 0)
                if panel.console:
                    end, text = panel.console.since(pos)
                else:
                    end, text = 0, ""
                self.reply(200, {"pos": end, "text": text})
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if self.path == "/api/upload/vga":
                    limit = JPEG_LIMIT
                    if not 0 < size <= limit:
                        raise ValueError("文件大小超出限制或为空")
                    target = SERVICES.directory / (uuid.uuid4().hex + ".jpg")
                    try:
                        with target.open("wb") as out:
                            remaining = size
                            while remaining:
                                block = self.rfile.read(min(1024 * 1024, remaining))
                                if not block:
                                    raise ValueError("上传中断")
                                out.write(block)
                                remaining -= len(block)
                        SERVICES.set_vga(str(target))
                    except Exception:
                        target.unlink(missing_ok=True)
                        raise
                    self.reply(200, {"ok": True})
                    return
                if not 0 < size <= 65536:
                    raise ValueError("无效的请求大小")
                body = json.loads(self.rfile.read(size))
                if self.path == "/api/cmd":
                    run_command(host, qmp, shlex.split(body["cmd"]))
                elif self.path == "/api/console" and panel.console:
                    panel.console.send(body["text"])
                else:
                    raise ValueError("unknown request")
                self.reply(200, {"ok": True})
            except (RuntimeError, KeyError, ValueError, OSError, StopIteration, struct.error) as exc:
                log("error: %s" % exc)
                self.reply(400, {"error": str(exc)})

    # localhost only: the panel drives the simulated hardware
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = "http://localhost:%d" % port
    log("control panel on %s" % url)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--qmp", default=os.path.expanduser("~/qemu-ceb-gnrd/qmp.sock"))
    parser.add_argument("--post", type=float, default=20, help="POST time in s")
    parser.add_argument("--shutdown", type=float, default=10, help="OS shutdown time in s")
    parser.add_argument("--gui", action="store_true",
                        help="control panel: a window when there is a display, else the web panel")
    parser.add_argument("--web", action="store_true",
                        help="with --gui: always the web panel (http://localhost:PORT)")
    parser.add_argument("--port", type=int, default=8800, help="control panel port")
    parser.add_argument("--state-dir", default=os.path.expanduser("~/qemu-ceb-gnrd"))
    parser.add_argument("--headless", action="store_true", help="host I/O worker without a panel or stdin")
    parser.add_argument("--uart", default=os.path.expanduser("~/qemu-ceb-gnrd/host-uart.sock"),
                        help="host serial port socket (the panel plays the host console)")
    args = parser.parse_args()

    qmp = Qmp(args.qmp)
    try:
        qmp.execute("qom-get", path=HOST_DEV, property="state")
        builtin = True
    except RuntimeError:
        builtin = False
    if builtin:
        host = BuiltinHost(qmp, args.post, args.shutdown)
        log("host simulated inside QEMU (bmc-host-sim), state: %s" % host.state)
    else:
        host = Host(qmp, args.post, args.shutdown)
        try:
            host.set_power(False, False)
            qmp.set(PWR_BTN_IN, True)
            qmp.set(UID_BTN, True)
        except RuntimeError as exc:
            sys.exit("GPIO not available through QMP: %s" % exc)
    # ADC inputs at the nominal rails (run-qemu.sh also passes them with
    # -global; set them here too so they do not depend on that)
    for i, mv in enumerate(ADC_NOMINAL_MV):
        try:
            if qmp.execute("qom-get", path=ADC, property="ch%d-mv" % i) < 0:
                qmp.execute("qom-set", path=ADC, property="ch%d-mv" % i, value=mv)
        except RuntimeError:
            break               # a QEMU without settable ADC inputs
    for name, (path, celsius) in TEMPS.items():
        try:
            qmp.set_temp(path, celsius)
        except RuntimeError as exc:
            log("temperature sensor %s not available: %s" % (name, exc))
    global HOST, HOST_IO, USB, SERVICES
    HOST = host
    SERVICES = PanelServices(qmp, args.state_dir, log)
    if qom(qmp, ESPI, "peripheral-ready") is not None:
        HOST_IO = HostIO(qmp)
        log("主机 COM1 / POST / KCS 使用 eSPI Peripheral 路由")
    if qom(qmp, VHUB, "host-connected") is not None:
        USB = USBHost(HOST_IO or HostIO(qmp), log)
    if args.gui:
        log("simulated host ready (%s)" % host.state)
    else:
        log("simulated host ready (%s). Type 'help' for commands." % host.state)

    def loop():
        screen = None
        video_available = qom(qmp, VIDEO, "signal") is not None
        last_error = 0
        while True:
            try:
                host.step()
                key = (host.state, qmp.resets, SERVICES.video_generation)
                if video_available and key != screen:
                    set_screen(qmp, host.state)
                    screen = key  # failed updates are retried
            except RuntimeError as exc:
                if time.monotonic() - last_error > 5:
                    log("QMP error: %s" % exc)
                    last_error = time.monotonic()
            time.sleep(POLL_S)

    threading.Thread(target=loop, daemon=True).start()
    console = ESPIConsole(HOST_IO) if HOST_IO else HostConsole(args.uart)
    panel = Panel(host, qmp, console)

    def usb_loop():
        seen_reset = qmp.resets
        last_error = 0
        while True:
            try:
                if seen_reset != qmp.resets:
                    seen_reset = qmp.resets
                    USB.set_connected(False)
                powered = host.state != "off"
                if USB.connected != powered:
                    USB.set_connected(powered)
                if powered:
                    USB.poll()
            except (RuntimeError, OSError, ValueError, KeyError, struct.error) as exc:
                USB.state = dict(USB.state, error=str(exc))
                if time.monotonic() - last_error > 10:
                    log("USB: %s" % exc)
                    last_error = time.monotonic()
                time.sleep(1)
            time.sleep(0.1)

    if USB:
        threading.Thread(target=usb_loop, daemon=True).start()
    if args.headless:
        threading.Event().wait()
        return

    if args.gui:
        if not args.web and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            try:
                sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
                import panel_tk
                window = panel_tk.PanelWindow(
                    panel, lambda text: run_command(host, qmp, shlex.split(text)), SERVICES)
            except Exception as exc:      # no Tk (python3-tk) or no display
                log("no panel window (%s), serving the web panel instead" % exc)
            else:
                log("control panel window open")
                window.mainloop()
                return
        serve_panel(panel, args.port, host, qmp)
        return

    for line in sys.stdin:
        try:
            words = shlex.split(line)
            if not words:
                continue
            if words[0] in ("quit", "exit"):
                break
            run_command(host, qmp, words)
        except (RuntimeError, KeyError, ValueError) as exc:
            log("error: %s" % exc)


if __name__ == "__main__":
    main()
