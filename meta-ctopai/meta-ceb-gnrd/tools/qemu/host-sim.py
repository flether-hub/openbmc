#!/usr/bin/env python3
"""Simulated host for the ceb-gnrd BMC running in QEMU (run-qemu.sh).

It talks to QEMU's QMP socket and plays the part of the motherboard behind the
BMC's GPIOs, using only what QEMU already emulates:

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
  post <s> | shutdown <s>
  quit

Usage: host-sim.py [--qmp ~/qemu-ceb-gnrd/qmp.sock] [--post 20] [--shutdown 10]
Python 3 standard library only.
"""

import argparse
import json
import os
import socket
import sys
import threading
import time

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

TEMPS = {
    "inlet": ("/machine/peripheral/temp-inlet", 25.0),
    "outlet": ("/machine/peripheral/temp-outlet", 35.0),
    "pcie": ("/machine/peripheral/temp-pcie", 40.0),
    "m2": ("/machine/peripheral/temp-m2", 38.0),
}
WATCHED = {ALERT_LED: "alert LED", UID_LED: "UID LED",
           FLASH_SEL: "BIOS flash select (1 = BMC)",
           FAN_OVERRIDE: "fan override (1 = BMC)"}
FORCE_OFF_S = 4.0
POLL_S = 0.05


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


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
        self._read()                                   # greeting
        self.execute("qmp_capabilities")

    def _read(self):
        line = self.file.readline()
        if not line:
            sys.exit("QEMU closed the QMP connection")
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
                # asynchronous event: ignore

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
            power_low = not self.q.get(POWER_OUT)
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

            reset_low = not self.q.get(RESET_OUT)
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
                value = self.q.get(pin)
                if self.outputs.get(pin) != value:
                    if pin in self.outputs:
                        log("BMC: %s -> %d" % (name, value))
                    self.outputs[pin] = value
                    if pin == FLASH_SEL and value and self.state != "off":
                        log("WARNING: the BMC took the BIOS flash while the host is %s"
                            % self.state)

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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--qmp", default=os.path.expanduser("~/qemu-ceb-gnrd/qmp.sock"))
    parser.add_argument("--post", type=float, default=20, help="POST time in s")
    parser.add_argument("--shutdown", type=float, default=10, help="OS shutdown time in s")
    args = parser.parse_args()

    qmp = Qmp(args.qmp)
    host = Host(qmp, args.post, args.shutdown)
    try:
        host.set_power(False, False)
        qmp.set(PWR_BTN_IN, True)
        qmp.set(UID_BTN, True)
    except RuntimeError as exc:
        sys.exit("GPIO not available through QMP: %s" % exc)
    for name, (path, celsius) in TEMPS.items():
        try:
            qmp.set_temp(path, celsius)
        except RuntimeError as exc:
            log("temperature sensor %s not available: %s" % (name, exc))
    log("simulated host ready (off). Type 'help' for commands.")

    def loop():
        while True:
            try:
                host.step()
            except RuntimeError as exc:
                log("QMP error: %s" % exc)
            time.sleep(POLL_S)

    threading.Thread(target=loop, daemon=True).start()

    for line in sys.stdin:
        words = line.split()
        if not words:
            continue
        cmd, rest = words[0], words[1:]
        try:
            if cmd in ("quit", "exit"):
                break
            elif cmd == "status":
                host.status()
            elif cmd == "power":
                host.front_panel_power(0.5)
            elif cmd == "power-hold":
                host.front_panel_power(5.0)
            elif cmd == "uid":
                host.press(UID_BTN, 0.5, "UID button")
            elif cmd == "hang" and rest and rest[0] in ("on", "off"):
                host.hang = rest[0] == "on"
                log("BIOS hang %s (applies to the next POST)" % rest[0])
            elif cmd == "powerfail":
                with host.lock:
                    host.power_off("power failure")
            elif cmd == "temp" and len(rest) == 2:
                names = list(TEMPS) if rest[0] == "all" else [rest[0]]
                for name in names:
                    qmp.set_temp(TEMPS[name][0], float(rest[1]))
                log("temperature %s = %s C" % (rest[0], rest[1]))
            elif cmd == "post" and rest:
                host.post_s = float(rest[0])
            elif cmd == "shutdown" and rest:
                host.shutdown_s = float(rest[0])
            else:
                print("commands: status | power | power-hold | uid | hang on|off | "
                      "powerfail | temp <inlet|outlet|pcie|m2|all> <C> | "
                      "post <s> | shutdown <s> | quit")
        except (RuntimeError, KeyError, ValueError) as exc:
            log("error: %s" % exc)


if __name__ == "__main__":
    main()
