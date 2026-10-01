#!/usr/bin/env python3

import json
import logging
import os
import subprocess
import threading
import time


LOG = logging.getLogger("ceb-gnrd-alert-led")
LED_BRIGHTNESS = "/sys/class/leds/bmc-system-alert/brightness"
STATE_DIR = "/run/ceb-gnrd-alert-led"
WATCHDOG_LATCH = os.path.join(STATE_DIR, "watchdog-timeout")
BOOT_LATCH = os.path.join(STATE_DIR, "bios-boot-timeout")
BOOT_TIMEOUT_SECONDS = 600

MAPPER = "xyz.openbmc_project.ObjectMapper"
MAPPER_PATH = "/xyz/openbmc_project/object_mapper"
MAPPER_INTERFACE = "xyz.openbmc_project.ObjectMapper"
SENSOR_VALUE = "xyz.openbmc_project.Sensor.Value"
# Entity-Manager "Severity" 4 (non-recoverable) is published as HardShutdown.
VOLTAGE_ROOT = "/xyz/openbmc_project/sensors/voltage"
TEMPERATURE_ROOT = "/xyz/openbmc_project/sensors/temperature"
THRESHOLD_INTERFACES = (
    "xyz.openbmc_project.Sensor.Threshold.Warning",
    "xyz.openbmc_project.Sensor.Threshold.Critical",
    "xyz.openbmc_project.Sensor.Threshold.PerformanceLoss",
    "xyz.openbmc_project.Sensor.Threshold.SoftShutdown",
    "xyz.openbmc_project.Sensor.Threshold.HardShutdown",
)
# Temperature alerts only follow the upper critical (and the higher upper
# non-recoverable) thresholds; warning level and low alarms do not light the LED.
TEMPERATURE_ALARM_PROPERTIES = ("CriticalAlarmHigh", "HardShutdownAlarmHigh")
WATCHDOG_MATCH = (
    "type='signal',interface='xyz.openbmc_project.Watchdog',"
    "member='Timeout',path='/xyz/openbmc_project/watchdog/host0'"
)


def busctl(*args):
    return subprocess.run(
        ["busctl", "--system", *args],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )


def unwrap_reply(data):
    # busctl --json wraps the reply arguments in a list.
    if isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict):
        return data[0]
    return data


def unwrap_variant(value):
    while isinstance(value, dict) and "type" in value and "data" in value:
        value = value["data"]
    return value


def mapper_sensors(root):
    # The mapper only reports the requested interfaces, so the threshold
    # interfaces must be part of the filter to be visible in the result.
    interfaces = (SENSOR_VALUE,) + THRESHOLD_INTERFACES
    result = busctl(
        "--json=short",
        "call",
        MAPPER,
        MAPPER_PATH,
        MAPPER_INTERFACE,
        "GetSubTree",
        "sias",
        root,
        "0",
        str(len(interfaces)),
        *interfaces,
    )
    payload = unwrap_reply(json.loads(result.stdout)["data"])
    if isinstance(payload, dict):
        payload = list(payload.items())

    sensors = []
    for entry in payload:
        if not isinstance(entry, list) or len(entry) != 2:
            continue
        path, services = entry
        if isinstance(services, dict):
            services = list(services.items())
        for service_entry in services:
            if not isinstance(service_entry, list) or len(service_entry) != 2:
                continue
            service, interfaces = service_entry
            if isinstance(interfaces, dict):
                interfaces = list(interfaces)
            sensors.append((service, path, set(interfaces)))
    return sensors


def get_all_properties(service, path, interface):
    result = busctl(
        "--json=short",
        "call",
        service,
        path,
        "org.freedesktop.DBus.Properties",
        "GetAll",
        "s",
        interface,
    )
    return unwrap_reply(json.loads(result.stdout)["data"])


def property_map(data):
    if isinstance(data, dict):
        return data
    if isinstance(data, list):
        return {pair[0]: pair[1] for pair in data if isinstance(pair, list) and len(pair) == 2}
    return {}


def as_bool(value):
    value = unwrap_variant(value)
    while isinstance(value, list) and value:
        value = unwrap_variant(value[-1])
    return value is True or value == 1 or value == "true"


def any_alarm(root, property_filter):
    """True if any sensor under root has an asserted alarm accepted by
    property_filter(name); None when the state cannot be determined."""
    try:
        sensors = mapper_sensors(root)
        if not sensors:
            return None
        for service, path, interfaces in sensors:
            for interface in THRESHOLD_INTERFACES:
                if interface not in interfaces:
                    continue
                props = property_map(get_all_properties(service, path, interface))
                for name, value in props.items():
                    if property_filter(name) and as_bool(value):
                        return True
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError) as exc:
        LOG.warning("Unable to read threshold alarms under %s: %s", root, exc)
        return None
    return False


def voltage_alarm_property(name):
    return name.endswith("AlarmHigh") or name.endswith("AlarmLow")


def temperature_alarm_property(name):
    return name in TEMPERATURE_ALARM_PROPERTIES


def sel_add(message, path, data=(0x00, 0xFF, 0xFF)):
    """Add an IPMI SEL record through phosphor-sel-logger (asserted event)."""
    for attempt in range(3):
        try:
            busctl(
                "call",
                "xyz.openbmc_project.Logging.IPMI",
                "/xyz/openbmc_project/Logging/IPMI",
                "xyz.openbmc_project.Logging.IPMI",
                "IpmiSelAdd",
                "ssaybq",
                message,
                path,
                str(len(data)),
                *[hex(b) for b in data],
                "true",
                "0x0020",
            )
            return True
        except (OSError, subprocess.SubprocessError) as exc:
            LOG.warning("SEL add failed (attempt %d): %s", attempt + 1, exc)
            time.sleep(1)
    return False


def read_gpio(line_name):
    found = subprocess.run(
        ["gpiofind", line_name], check=True, capture_output=True, text=True, timeout=5
    ).stdout.split()
    if len(found) != 2:
        raise RuntimeError("unexpected gpiofind result for %s" % line_name)
    result = subprocess.run(
        ["gpioget", found[0], found[1]],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    return result.stdout.strip() in ("1", "active")


def watchdog_monitor():
    while True:
        try:
            proc = subprocess.Popen(
                ["busctl", "--system", "--match=" + WATCHDOG_MATCH, "monitor"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                if "member=Timeout" in line or "Member=Timeout" in line:
                    os.makedirs(STATE_DIR, exist_ok=True)
                    with open(WATCHDOG_LATCH, "w", encoding="ascii") as latch:
                        latch.write("watchdog timeout\n")
                    LOG.error("Host watchdog timeout latched system alert")
            proc.wait()
        except (OSError, subprocess.SubprocessError) as exc:
            LOG.warning("Watchdog signal monitor failed: %s", exc)
        time.sleep(2)


def set_led(on):
    value = "1\n" if on else "0\n"
    try:
        with open(LED_BRIGHTNESS, "w", encoding="ascii") as led:
            led.write(value)
        return True
    except OSError as exc:
        LOG.error("Unable to set system alert LED: %s", exc)
        return False


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    os.makedirs(STATE_DIR, exist_ok=True)
    threading.Thread(target=watchdog_monitor, daemon=True).start()

    boot_deadline = None
    boot_succeeded = False
    boot_failed = os.path.exists(BOOT_LATCH)
    watchdog_failed = os.path.exists(WATCHDOG_LATCH)
    # One shared system alert LED.  Voltage and temperature alarms follow the
    # sensors: the LED goes out once they are de-asserted.  The watchdog and BIOS
    # boot failures are latched until the BMC is rebooted.
    voltage_alarm = False
    temperature_alarm = False
    led_state = None

    while True:
        try:
            power_good = read_gpio("BMC_CPU_PWRGD")
            boot_ok = read_gpio("BMC_BIOS_BOOT_OK")
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            LOG.warning("Unable to read host boot GPIOs: %s", exc)
        else:
            now = time.monotonic()
            if not power_good:
                boot_deadline = None
                boot_succeeded = False
            elif boot_ok:
                # BOOT_OK only suppresses this boot's timeout; it has no
                # separate LED, SEL, or power-control action.
                boot_deadline = None
                boot_succeeded = True
            elif not boot_succeeded and boot_deadline is None and not boot_failed:
                boot_deadline = now + BOOT_TIMEOUT_SECONDS
                LOG.info("BIOS boot watchdog started (%d seconds)", BOOT_TIMEOUT_SECONDS)

            if boot_deadline is not None and now >= boot_deadline:
                with open(BOOT_LATCH, "w", encoding="ascii") as latch:
                    latch.write("BIOS boot timeout\n")
                boot_failed = True
                boot_deadline = None
                LOG.error("BIOS did not assert BOOT_OK within %d seconds", BOOT_TIMEOUT_SECONDS)
                sel_add(
                    "BIOS boot failure: BOOT_OK not asserted within %d seconds"
                    % BOOT_TIMEOUT_SECONDS,
                    "/xyz/openbmc_project/state/host0",
                )

        watchdog_failed = watchdog_failed or os.path.exists(WATCHDOG_LATCH)
        voltage_state = any_alarm(VOLTAGE_ROOT, voltage_alarm_property)
        if voltage_state is not None:
            voltage_alarm = voltage_state
        temperature_state = any_alarm(TEMPERATURE_ROOT, temperature_alarm_property)
        if temperature_state is not None:
            temperature_alarm = temperature_state
        alert = voltage_alarm or temperature_alarm or boot_failed or watchdog_failed
        if alert != led_state and set_led(alert):
            led_state = alert
        time.sleep(2)


if __name__ == "__main__":
    main()
