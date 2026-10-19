#!/usr/bin/env python3

import json
import logging
import math
import os
import socket
import subprocess
import threading
import time


LOG = logging.getLogger("ceb-gnrd-alert-led")


class JournalFormatter(logging.Formatter):
    """Keep each Python record's actual priority in the systemd journal."""
    def format(self, record):
        priority = (2 if record.levelno >= logging.CRITICAL else
                    3 if record.levelno >= logging.ERROR else
                    4 if record.levelno >= logging.WARNING else
                    6 if record.levelno >= logging.INFO else 7)
        return "<%d>%s" % (priority, super().format(record))
# The system alert LED is the "fault" LED of phosphor-led-manager: this service only
# asserts or de-asserts the standard enclosure_fault group, the LED manager drives
# the physical LED (kernel LED label "fault", see led.json).
LED_GROUP_SERVICE = "xyz.openbmc_project.LED.GroupManager"
LED_GROUP_PATH = "/xyz/openbmc_project/led/groups/enclosure_fault"
LED_GROUP_INTERFACE = "xyz.openbmc_project.Led.Group"
LED_REASSERT_SECONDS = 30
STATE_DIR = "/run/ceb-gnrd-alert-led"
WATCHDOG_LATCH = os.path.join(STATE_DIR, "watchdog-timeout")
WATCHDOG_ALARM = threading.Event()
WATCHDOG_LATCH_RETRY_SECONDS = 30
BOOT_LATCH = os.path.join(STATE_DIR, "bios-boot-timeout")
SENSOR_ALARM_CACHE = os.path.join(STATE_DIR, "sensor-alarms.json")
BOOT_TIMEOUT_SECONDS = 600
BOOT_LATCH_RETRY_SECONDS = 30

MAPPER = "xyz.openbmc_project.ObjectMapper"
MAPPER_PATH = "/xyz/openbmc_project/object_mapper"
MAPPER_INTERFACE = "xyz.openbmc_project.ObjectMapper"
SENSOR_VALUE = "xyz.openbmc_project.Sensor.Value"
SENSOR_QUALITY = {
    "xyz.openbmc_project.State.Decorator.Availability": "Available",
    "xyz.openbmc_project.State.Decorator.OperationalStatus": "Functional",
}
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
# CPU / DIMM maximum temperatures also light the LED at Upper Critical.
# Other temperatures retain the upper non-recoverable policy.
TEMPERATURE_CRITICAL_SENSORS = {"CPU_MAX_TEMP", "DIMM_MAX_TEMP"}
TEMPERATURE_ALARM_PROPERTIES = ("NonRecoverableAlarmHigh",)
# These rails use PowerState=ChassisOn in ceb-gnrd.json. Standby/PSU/inlet
# sensors remain eligible while the host is off, including their real alarms.
HOST_POWERED_SENSORS = TEMPERATURE_CRITICAL_SENSORS | {
    "P12V_SYS", "P5V0_SYS", "P3V3_SYS", "PVCCIN_CPU", "PVNN_NAC_CPU",
    "PVCCD0_HV_CPU", "PVCCINF_CPU", "PVNN_MAIN_CPU", "PVCCFA_EHV_CPU",
    "PVCCD1_HV_CPU", "PVCCINF_EHV_FIVRA_CPU",
}
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
    interfaces = (SENSOR_VALUE,) + THRESHOLD_INTERFACES + tuple(SENSOR_QUALITY)
    result = busctl(
        "--json=short",
        "call",
        MAPPER,
        MAPPER_PATH,
        MAPPER_INTERFACE,
        "GetSubTree",
        "sias",
        "/",
        "0",
        str(len(interfaces)),
        *interfaces,
    )
    payload = unwrap_reply(json.loads(result.stdout)["data"])
    if isinstance(payload, dict):
        payload = list(payload.items())

    sensors = []
    for entry in payload:
        # (path, services): a tuple when it came from dict.items()
        if not isinstance(entry, (list, tuple)) or len(entry) != 2:
            continue
        path, services = entry
        # Querying the mapper root yields an empty list while a sensor subtree
        # has not appeared yet, rather than ResourceNotFound. Keep polling and
        # retain the last known alarm until the requested subtree is ready.
        if not isinstance(path, str) or not path.startswith(root.rstrip("/") + "/"):
            continue
        if isinstance(services, dict):
            services = list(services.items())
        for service_entry in services:
            if not isinstance(service_entry, (list, tuple)) or len(service_entry) != 2:
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


missing_sensor_since = {}
missing_sensor_reported = set()
# Keep an asserted fault until that exact property explicitly clears. A
# temporarily absent provider is not a recovery. /run retains this across an
# alert-service restart, but it starts fresh on an actual BMC reboot.
sensor_alarms = set()


def load_sensor_alarms():
    try:
        with open(SENSOR_ALARM_CACHE, encoding="utf-8") as handle:
            entries = json.load(handle)
        if not isinstance(entries, list):
            raise ValueError("alarm cache is not a list")
        for entry in entries:
            if (not isinstance(entry, list) or len(entry) != 4
                    or not all(isinstance(value, str) for value in entry)
                    or entry[0] not in (VOLTAGE_ROOT, TEMPERATURE_ROOT)):
                raise ValueError("invalid alarm cache entry")
        sensor_alarms.update(tuple(entry) for entry in entries)
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError) as exc:
        LOG.error("Unable to restore sensor alarm state: %s", exc)


def save_sensor_alarms(previous):
    if previous == sensor_alarms:
        return
    try:
        temporary = SENSOR_ALARM_CACHE + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(sorted(sensor_alarms), handle)
        os.replace(temporary, SENSOR_ALARM_CACHE)
    except OSError as exc:
        LOG.error("Unable to retain sensor alarm state for service restart: %s", exc)


def any_alarm(root, property_filter, host_off=False):
    """True if any sensor under root has an asserted alarm accepted by
    property_filter(path, name); None when the state cannot be determined."""
    previous = sensor_alarms.copy()
    cleared_for_power_off = False
    if host_off:
        inactive = {entry for entry in sensor_alarms if entry[0] == root
                    and entry[1].rsplit("/", 1)[-1] in HOST_POWERED_SENSORS}
        sensor_alarms.difference_update(inactive)
        cleared_for_power_off = bool(inactive)
        save_sensor_alarms(previous)
    try:
        sensors = mapper_sensors(root)
        if not sensors:
            since = missing_sensor_since.setdefault(root, time.monotonic())
            if time.monotonic() - since >= 60 and root not in missing_sensor_reported:
                LOG.warning("No sensors under %s for 60 seconds; alarm state is unknown", root)
                missing_sensor_reported.add(root)
            if any(entry[0] == root for entry in sensor_alarms):
                return True
            return False if cleared_for_power_off else None
        missing_sensor_since.pop(root, None)
        if root in missing_sensor_reported:
            LOG.info("Sensor discovery recovered under %s", root)
            missing_sensor_reported.discard(root)
        for service, path, interfaces in sensors:
            sd_notify("WATCHDOG=1")
            if host_off and path.rsplit("/", 1)[-1] in HOST_POWERED_SENSORS:
                continue
            can_clear = True
            if any(entry[0] == root and entry[1] == path for entry in sensor_alarms):
                # A restarted provider initially exports false alarms before
                # its first sample. Only healthy telemetry confirms recovery.
                for interface, property_name in SENSOR_QUALITY.items():
                    if interface in interfaces:
                        quality = property_map(get_all_properties(service, path, interface))
                        if not as_bool(quality.get(property_name)):
                            can_clear = False
                if can_clear:
                    if SENSOR_VALUE not in interfaces:
                        can_clear = False
                    else:
                        values = property_map(get_all_properties(service, path, SENSOR_VALUE))
                        reading = unwrap_variant(values.get("Value"))
                        while isinstance(reading, list) and len(reading) == 1:
                            reading = unwrap_variant(reading[0])
                        # Some providers initially export healthy quality but
                        # NaN Value. Their default false alarm is not recovery.
                        can_clear = (not isinstance(reading, bool)
                                     and isinstance(reading, (int, float))
                                     and math.isfinite(reading))
            for interface in THRESHOLD_INTERFACES:
                if interface not in interfaces:
                    continue
                props = property_map(get_all_properties(service, path, interface))
                for name, value in props.items():
                    if not property_filter(path, name):
                        continue
                    key = (root, path, interface, name)
                    if as_bool(value):
                        sensor_alarms.add(key)
                    elif can_clear:
                        sensor_alarms.discard(key)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError) as exc:
        save_sensor_alarms(previous)
        LOG.warning("Unable to read threshold alarms under %s: %s", root, exc)
        if any(entry[0] == root for entry in sensor_alarms):
            return True
        return False if cleared_for_power_off else None
    save_sensor_alarms(previous)
    return any(entry[0] == root for entry in sensor_alarms)


def voltage_alarm_property(path, name):
    return name.endswith("AlarmHigh") or name.endswith("AlarmLow")


def temperature_alarm_property(path, name):
    return name in TEMPERATURE_ALARM_PROPERTIES or (
        path.rsplit("/", 1)[-1] in TEMPERATURE_CRITICAL_SENSORS
        and name == "CriticalAlarmHigh"
    )


def sel_add(message, sensor_type, data=(0x00, 0xFF, 0xFF)):
    """Add an IPMI SEL record through phosphor-sel-logger (asserted event)."""
    for attempt in range(3):
        try:
            busctl(
                "call",
                "xyz.openbmc_project.Logging.IPMI",
                "/xyz/openbmc_project/Logging/IPMI",
                "xyz.openbmc_project.Logging.IPMI",
                "IpmiSelAddPlatform",
                "syyyaybq",
                message,
                hex(sensor_type),
                "0xff",  # this software event has no actual SDR sensor
                "0x6f",  # sensor-specific event offset, IPMI 2.0 Table 42-3
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
INTRUSION_SENSOR_TYPE = 0x05
BIOS_FIRMWARE_SENSOR_TYPE = 0x0F
# System Firmware Hang, unspecified initialization step; no invented POST code.
BIOS_HANG_SEL_DATA = (0x01, 0xFF, 0xFF)
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
        proc = None
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
                    # Latch before any filesystem operation. The main loop
                    # persists this alarm and retries failures independently.
                    if not WATCHDOG_ALARM.is_set():
                        WATCHDOG_ALARM.set()
                        LOG.error("Host watchdog timeout latched system alert")
            LOG.warning("Watchdog signal monitor exited: %s", proc.wait())
        except (OSError, subprocess.SubprocessError) as exc:
            LOG.warning("Watchdog signal monitor failed: %s", exc)
        finally:
            if proc is not None:
                # Always reap the old monitor before launching its replacement.
                try:
                    if proc.poll() is None:
                        try:
                            proc.terminate()
                        except ProcessLookupError:
                            pass  # The monitor exited between poll and signal.
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                finally:
                    if proc.stdout is not None:
                        proc.stdout.close()
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
    for handler in logging.getLogger().handlers:
        handler.setFormatter(JournalFormatter("%(levelname)s %(message)s"))
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
    except OSError as exc:
        # A full /run must not prevent live alarms or reset the boot watchdog
        # through repeated service startup failures. Latches retry below.
        LOG.error("Unable to create alarm state directory; using memory state: %s", exc)
    load_sensor_alarms()
    threading.Thread(target=watchdog_monitor, daemon=True).start()

    boot_deadline = None
    boot_failed = os.path.exists(BOOT_LATCH)
    boot_latch_saved = boot_failed
    boot_latch_retry_at = 0.0
    watchdog_failed = os.path.exists(WATCHDOG_LATCH)
    watchdog_latch_saved = watchdog_failed
    if watchdog_failed:
        WATCHDOG_ALARM.set()
    watchdog_latch_retry_at = 0.0
    # One shared system alert LED. Voltage, temperature upper non-recoverable,
    # and CPU / DIMM Upper Critical alarms follow the sensors. The LED goes out
    # when all fault sources clear. BIOS boot failure clears on a successful
    # POST; host watchdog failure remains latched until the BMC is rebooted.
    voltage_alarm = False
    temperature_alarm = False
    led_state = None
    led_set_at = 0.0
    intrusion_last = None
    sd_notify("READY=1")

    while True:
        sd_notify("WATCHDOG=1")
        power_good = None
        try:
            power_good = chassis_power_on()
            boot_ok = bios_boot_ok()
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            LOG.warning("Unable to read the host power / boot state: %s", exc)
        else:
            now = time.monotonic()
            if not power_good:
                boot_deadline = None
            elif boot_ok:
                boot_deadline = None
                # A successful POST proves recovery, including after a host
                # reset following a timeout. Remove the latch as well so an
                # alert service restart cannot restore the old fault.
                if boot_failed:
                    try:
                        os.unlink(BOOT_LATCH)
                    except FileNotFoundError:
                        boot_failed = False
                    except OSError as exc:
                        LOG.warning("Unable to clear BIOS boot timeout latch: %s", exc)
                    else:
                        boot_failed = False
                    if not boot_failed:
                        boot_latch_saved = False
                        boot_latch_retry_at = 0.0
                        LOG.info("BIOS POST complete: boot timeout fault cleared")
            else:
                # POST_COMPLETE drops on a warm reset while chassis power
                # stays on. A previous successful boot must not suppress
                # monitoring of the new BIOS boot.
                if boot_deadline is None and not boot_failed:
                    boot_deadline = now + BOOT_TIMEOUT_SECONDS
                    LOG.info("BIOS boot watchdog started (%d seconds)", BOOT_TIMEOUT_SECONDS)

            if boot_deadline is not None and now >= boot_deadline:
                # Latch in memory before touching storage. Failure to retain
                # the marker must not skip SEL/LED handling or restart this
                # process and grant another 600-second boot deadline.
                boot_failed = True
                boot_latch_saved = False
                boot_latch_retry_at = 0.0
                boot_deadline = None
                LOG.error("BIOS did not assert BOOT_OK within %d seconds", BOOT_TIMEOUT_SECONDS)
                sel_add(
                    "BIOS boot failure: BOOT_OK not asserted within %d seconds"
                    % BOOT_TIMEOUT_SECONDS,
                    BIOS_FIRMWARE_SENSOR_TYPE, BIOS_HANG_SEL_DATA,
                )

        if boot_failed and not boot_latch_saved:
            now = time.monotonic()
            if now >= boot_latch_retry_at:
                boot_latch_retry_at = now + BOOT_LATCH_RETRY_SECONDS
                try:
                    os.makedirs(STATE_DIR, exist_ok=True)
                    with open(BOOT_LATCH, "w", encoding="ascii") as latch:
                        latch.write("BIOS boot timeout\n")
                except OSError as exc:
                    LOG.warning("Unable to persist BIOS boot timeout latch; "
                                "alarm remains active, retrying: %s", exc)
                else:
                    boot_latch_saved = True

        # Chassis intrusion: one SEL record (and, through sel-logger, one Redfish
        # event) when the sensor leaves Normal.  It does not light the alert LED.
        status = intrusion_status()
        if status is not None:
            # the status is the D-Bus enum string, e.g.
            # "xyz.openbmc_project.Chassis.Intrusion.Status.Normal"
            normal = status.rsplit(".", 1)[-1] == INTRUSION_NORMAL
            if not normal and status != intrusion_last:
                LOG.error("Chassis intrusion detected (%s)", status)
                if not sel_add("Chassis intrusion detected", INTRUSION_SENSOR_TYPE, INTRUSION_SEL_DATA):
                    status = intrusion_last  # retry on the next cycle
            intrusion_last = status
        watchdog_failed = (watchdog_failed or WATCHDOG_ALARM.is_set()
                           or os.path.exists(WATCHDOG_LATCH))
        if watchdog_failed:
            WATCHDOG_ALARM.set()
            now = time.monotonic()
            if not watchdog_latch_saved and now >= watchdog_latch_retry_at:
                watchdog_latch_retry_at = now + WATCHDOG_LATCH_RETRY_SECONDS
                try:
                    os.makedirs(STATE_DIR, exist_ok=True)
                    with open(WATCHDOG_LATCH, "w", encoding="ascii") as latch:
                        latch.write("watchdog timeout\n")
                except OSError as exc:
                    LOG.warning("Unable to persist watchdog timeout latch; "
                                "alarm remains active, retrying: %s", exc)
                else:
                    watchdog_latch_saved = True
        voltage_state = any_alarm(VOLTAGE_ROOT, voltage_alarm_property,
                                  host_off=power_good is False)
        if voltage_state is not None:
            voltage_alarm = voltage_state
        temperature_state = any_alarm(TEMPERATURE_ROOT, temperature_alarm_property,
                                      host_off=power_good is False)
        if temperature_state is not None:
            if temperature_state != temperature_alarm:
                LOG.info("Temperature fault alarm %s", "asserted" if temperature_state else "cleared")
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
