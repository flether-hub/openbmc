#!/usr/bin/env python3

import json
import logging
import os
import socket
import subprocess
import threading
import time


LOG = logging.getLogger("ceb-gnrd-alert-led")
# The system alert LED is the "fault" LED of phosphor-led-manager: this service only
# asserts or de-asserts the standard enclosure_fault group, the LED manager drives
# the physical LED (kernel LED label "fault", see led.json).
LED_GROUP_SERVICE = "xyz.openbmc_project.LED.GroupManager"
LED_GROUP_PATH = "/xyz/openbmc_project/led/groups/enclosure_fault"
LED_GROUP_INTERFACE = "xyz.openbmc_project.Led.Group"
LED_REASSERT_SECONDS = 30
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
    # private interface of ceb-gnrd-temp-max (upper non-recoverable temperature)
    "com.ctopai.CebGnrd.Threshold.NonRecoverable",
)
# A temperature only lights the LED when the upper non-recoverable threshold is
# reached (the private interface of ceb-gnrd-temp-max); warning, critical and low
# alarms do not.
TEMPERATURE_ALARM_PROPERTIES = ("NonRecoverableAlarmHigh",)
WATCHDOG_MATCH = (
    "type='signal',interface='xyz.openbmc_project.Watchdog',"
    "member='Timeout',path='/xyz/openbmc_project/watchdog/host0'"
)


def sd_notify(message):
    """Tell systemd about READY / watchdog pings (Type=notify, WatchdogSec=)."""
    path = os.environ.get("NOTIFY_SOCKET")
    if not path:
        return
    if path[0] == "@":
        path = "\0" + path[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(path)
            sock.sendall(message.encode())
    except OSError:
        pass


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
            sd_notify("WATCHDOG=1")
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


INTRUSION_INTERFACE = "xyz.openbmc_project.Chassis.Intrusion"
INTRUSION_NORMAL = "Normal"
# IPMI sensor type 0x05 (Physical Security), event offset 0x00 (General Chassis
# Intrusion): the SEL event data byte 1 carries the offset.
INTRUSION_SEL_DATA = (0x00, 0xFF, 0xFF)
INTRUSION_SEL_PATH = "/xyz/openbmc_project/sensors/physical_security/Chassis_Intrusion"
_intrusion_object = None


def intrusion_status():
    """Status of the chassis intrusion sensor (dbus-sensors intrusionsensor,
    hwmon intrusion0_alarm): "Normal", "HardwareIntrusion", ...  None when the
    sensor object does not exist (no hardware, or the service is not up yet)."""
    global _intrusion_object
    try:
        if _intrusion_object is None:
            result = busctl(
                "--json=short", "call", MAPPER, MAPPER_PATH, MAPPER_INTERFACE,
                "GetSubTree", "sias", "/", "0", "1", INTRUSION_INTERFACE,
            )
            payload = unwrap_reply(json.loads(result.stdout)["data"])
            if isinstance(payload, dict):
                payload = list(payload.items())
            for path, services in payload:
                if isinstance(services, dict):
                    services = list(services.items())
                if services:
                    _intrusion_object = (services[0][0], path)
                    break
            if _intrusion_object is None:
                return None
        service, path = _intrusion_object
        result = busctl(
            "--json=short", "get-property", service, path, INTRUSION_INTERFACE, "Status",
        )
        return str(unwrap_variant(json.loads(result.stdout)))
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        LOG.debug("Chassis intrusion status unavailable: %s", exc)
        _intrusion_object = None
        return None

CHASSIS_STATE_SERVICE = "xyz.openbmc_project.State.Chassis"
CHASSIS_STATE_PATH = "/xyz/openbmc_project/state/chassis0"
CHASSIS_POWER_ON = "xyz.openbmc_project.State.Chassis.PowerState.On"


def chassis_power_on():
    """True when the host is powered on.  BMC_CPU_PWRGD cannot be read with
    gpioget: x86-power-control holds that line (it fails with "device or
    resource busy"), so use the chassis state it publishes from that line."""
    result = busctl(
        "--json=short",
        "get-property",
        CHASSIS_STATE_SERVICE,
        CHASSIS_STATE_PATH,
        "xyz.openbmc_project.State.Chassis",
        "CurrentPowerState",
    )
    try:
        return unwrap_variant(json.loads(result.stdout)) == CHASSIS_POWER_ON
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError("unexpected CurrentPowerState reply: %s" % exc)


OS_STATE_SERVICE = "xyz.openbmc_project.State.OperatingSystem"
OS_STATE_PATH = "/xyz/openbmc_project/state/host0"
OS_STATE_INTERFACE = "xyz.openbmc_project.State.OperatingSystem.Status"
# x86-power-control sets Standby while PostComplete (BMC_BIOS_BOOT_OK) is high
# and Inactive otherwise (also when the host is switched off).
OS_STATE_BOOT_OK = "xyz.openbmc_project.State.OperatingSystem.Status.OSStatus.Standby"


def bios_boot_ok():
    """True when the BIOS has signalled boot OK (POST complete).  BMC_BIOS_BOOT_OK
    is the PostComplete line of x86-power-control, which holds it exclusively, so
    read the OperatingSystemState it publishes instead of the GPIO."""
    result = busctl(
        "--json=short",
        "get-property",
        OS_STATE_SERVICE,
        OS_STATE_PATH,
        OS_STATE_INTERFACE,
        "OperatingSystemState",
    )
    try:
        return unwrap_variant(json.loads(result.stdout)) == OS_STATE_BOOT_OK
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError("unexpected OperatingSystemState reply: %s" % exc)


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
    """Assert (True) or de-assert (False) the enclosure_fault LED group."""
    try:
        busctl(
            "set-property",
            LED_GROUP_SERVICE,
            LED_GROUP_PATH,
            LED_GROUP_INTERFACE,
            "Asserted",
            "b",
            "true" if on else "false",
        )
        return True
    except (OSError, subprocess.SubprocessError) as exc:
        LOG.error("Unable to set the enclosure_fault LED group: %s", exc)
        return False

def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    os.makedirs(STATE_DIR, exist_ok=True)
    threading.Thread(target=watchdog_monitor, daemon=True).start()

    boot_deadline = None
    boot_succeeded = False
    boot_failed = os.path.exists(BOOT_LATCH)
    watchdog_failed = os.path.exists(WATCHDOG_LATCH)
    # One shared system alert LED.  A voltage alarm and a temperature upper
    # non-recoverable alarm follow the sensors: the LED goes out once they are
    # de-asserted.  The watchdog and BIOS
    # boot failures are latched until the BMC is rebooted.
    voltage_alarm = False
    temperature_alarm = False
    led_state = None
    led_set_at = 0.0
    intrusion_last = None
    sd_notify("READY=1")

    while True:
        sd_notify("WATCHDOG=1")
        try:
            power_good = chassis_power_on()
            boot_ok = bios_boot_ok()
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            LOG.warning("Unable to read the host power / boot state: %s", exc)
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

        # Chassis intrusion: one SEL record (and, through sel-logger, one Redfish
        # event) when the sensor leaves Normal.  It does not light the alert LED.
        status = intrusion_status()
        if status is not None:
            # the status is the D-Bus enum string, e.g.
            # "xyz.openbmc_project.Chassis.Intrusion.Status.Normal"
            normal = status.rsplit(".", 1)[-1] == INTRUSION_NORMAL
            if not normal and status != intrusion_last:
                LOG.error("Chassis intrusion detected (%s)", status)
                if not sel_add("Chassis intrusion detected", INTRUSION_SEL_PATH, INTRUSION_SEL_DATA):
                    status = intrusion_last  # retry on the next cycle
            intrusion_last = status
        watchdog_failed = watchdog_failed or os.path.exists(WATCHDOG_LATCH)
        voltage_state = any_alarm(VOLTAGE_ROOT, voltage_alarm_property)
        if voltage_state is not None:
            voltage_alarm = voltage_state
        temperature_state = any_alarm(TEMPERATURE_ROOT, temperature_alarm_property)
        if temperature_state is not None:
            temperature_alarm = temperature_state
        alert = voltage_alarm or temperature_alarm or boot_failed or watchdog_failed
        # Assert again every LED_REASSERT_SECONDS while alerting: the group is lost
        # when phosphor-led-manager restarts.
        stale = alert and time.monotonic() - led_set_at >= LED_REASSERT_SECONDS
        if (alert != led_state or stale) and set_led(alert):
            led_state = alert
            led_set_at = time.monotonic()
        time.sleep(2)


if __name__ == "__main__":
    main()
