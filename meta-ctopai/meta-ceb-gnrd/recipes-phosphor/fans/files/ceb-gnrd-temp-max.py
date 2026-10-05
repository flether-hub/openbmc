#!/usr/bin/env python3
"""CEB-GNRD CPU / DIMM maximum temperature sensors.

The kernel PECI drivers (peci_cputemp, peci_dimmtemp) expose one temperature per
CPU core and per DIMM as hwmon attributes.  They are deliberately not published
as D-Bus sensors (no IntelCPUSensor configuration), so IPMI, Redfish and the web
page show no per-core or per-DIMM sensor.  This service reads them and publishes
exactly two D-Bus sensors, the hottest value of each group:

    /xyz/openbmc_project/sensors/temperature/CPU_MAX_TEMP
    /xyz/openbmc_project/sensors/temperature/DIMM_MAX_TEMP

which phosphor-pid-control uses as its inputs (see ceb-gnrd.json).

The source temperatures are the temp*_input attributes of the hwmon devices whose
name starts with "peci_cputemp" (CPU) or "peci_dimmtemp" (DIMM), found by scanning
/sys/class/hwmon:
  * DIMM : every temperature of a peci_dimmtemp device
  * CPU  : every temperature of a peci_cputemp device, except margin style
           readings (DTS) and the Tcontrol / Tthrottle / Tjmax values (by label)

Upper thresholds (non-critical / critical / non-recoverable) are published on the
Warning / Critical threshold interfaces and a private NonRecoverable interface (not
HardShutdown, nothing may power the system off), so phosphor-sel-logger records the
alarms and IPMI shows UNC / UC / UNR.

When the host is off the value is 0 (no thermal load); when the host is on but
no source sensor is readable the value is FAILSAFE_TEMP.  Both fan curves in
ceb-gnrd.json give exactly 60 % at that temperature, so unreadable CPU or DIMM
temperatures run the fans at 60 %.  The zone's own fail-safe speed is kept at
the minimum on purpose: the number of readable fans must not decide the fan
speed.  No alarm is raised for the substitute value.

All discovered sources and their group are written to the journal whenever the
set changes:  journalctl -u ceb-gnrd-temp-max
"""

import asyncio
import logging
import math
import os
import re
import socket
import sys

from dbus_fast import BusType, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import (PropertyAccess, ServiceInterface, dbus_property, method,
                               signal)

LOG = logging.getLogger("ceb-gnrd-temp-max")

BUS_NAME = "com.ctopai.CebGnrd.TempMax"
SENSOR_BASE = "/xyz/openbmc_project/sensors"
SENSOR_ROOT = SENSOR_BASE + "/temperature"
INVENTORY_ROOT = "/xyz/openbmc_project/inventory"
BOARD_IFACE = "xyz.openbmc_project.Inventory.Item.Board"
ADC_ROOT = "/xyz/openbmc_project/sensors/voltage"
HWMON_ROOT = "/sys/class/hwmon"
VALUE_IFACE = "xyz.openbmc_project.Sensor.Value"
UNIT_DEGREES_C = "xyz.openbmc_project.Sensor.Value.Unit.DegreesC"
ASSOC_IFACE = "xyz.openbmc_project.Association.Definitions"
# Private interface for the upper non-recoverable threshold.  It is deliberately not
# xyz.openbmc_project.Sensor.Threshold.HardShutdown: services such as the fan
# sensor monitor power the system off on a HardShutdown alarm, and the BMC must
# not shut the system down.  The board patches of ipmid and sel-logger read it.
NONRECOVERABLE_IFACE = "com.ctopai.CebGnrd.Threshold.NonRecoverable"

MAPPER = "xyz.openbmc_project.ObjectMapper"
MAPPER_PATH = "/xyz/openbmc_project/object_mapper"
PROPS = "org.freedesktop.DBus.Properties"
CHASSIS_STATE = ("xyz.openbmc_project.State.Chassis",
                 "/xyz/openbmc_project/state/chassis0",
                 "xyz.openbmc_project.State.Chassis", "CurrentPowerState")

TEMP_INPUT_RE = re.compile(r"temp(\d+)_input$")
EXCLUDE_RE = re.compile(r"dts|tcontrol|tthrottle|tjmax|margin", re.IGNORECASE)

POLL_SECONDS = 2

# Published while the host is on but no temperature can be read: 70 degC, the
# point where both fan curves give 60 % (keep them in sync with ceb-gnrd.json)
FAILSAFE_TEMP = 70.0

# Upper thresholds in degrees C: (non-critical UNC, critical UC, non-recoverable UNR)
THRESHOLDS = {
    "CPU": (90.0, 98.0, 105.0),
    "DIMM": (80.0, 85.0, 95.0),
}


class TempSensor(ServiceInterface):
    def __init__(self, name):
        super().__init__(VALUE_IFACE)
        # not self.name: ServiceInterface keeps the D-Bus interface name there
        self.sensor_name = name
        self.value = math.nan

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "d":
        return self.value

    @dbus_property(access=PropertyAccess.READ)
    def Unit(self) -> "s":
        return UNIT_DEGREES_C

    @dbus_property(access=PropertyAccess.READ)
    def MaxValue(self) -> "d":
        return 127.0

    @dbus_property(access=PropertyAccess.READ)
    def MinValue(self) -> "d":
        return -128.0

    def update(self, value):
        if value != self.value and not (math.isnan(value) and math.isnan(self.value)):
            self.value = value
            self.emit_properties_changed({"Value": value})


class _Threshold(ServiceInterface):
    """Common state of one upper threshold level; subclasses expose the
    D-Bus property names of that level."""

    def __init__(self, interface, high):
        super().__init__(interface)
        self.interface_name = interface
        self.high = high
        self.alarm = False
        self._signal_args = ["", interface, "", False, 0.0]

    @signal()
    def ThresholdAsserted(self) -> "sssbd":
        # phosphor-sel-logger turns this signal into an IPMI SEL record.
        return self._signal_args

    def evaluate(self, sensor_name, value, alarm_name):
        if math.isnan(value):
            return False          # reading lost: keep the current alarm state
        alarm = value >= self.high
        if alarm != self.alarm:
            self.alarm = alarm
            self.emit_properties_changed({alarm_name: alarm})
            self._signal_args = [sensor_name, self.interface_name, alarm_name,
                                 alarm, value]
            self.ThresholdAsserted()
            return True
        return False


class WarningThreshold(_Threshold):
    def __init__(self, high):
        super().__init__("xyz.openbmc_project.Sensor.Threshold.Warning", high)

    def properties(self):
        return {"WarningHigh": Variant("d", self.high),
                "WarningLow": Variant("d", math.nan),
                "WarningAlarmHigh": Variant("b", self.alarm),
                "WarningAlarmLow": Variant("b", False)}

    @dbus_property(access=PropertyAccess.READ)
    def WarningHigh(self) -> "d":
        return self.high

    @dbus_property(access=PropertyAccess.READ)
    def WarningLow(self) -> "d":
        return math.nan

    @dbus_property(access=PropertyAccess.READ)
    def WarningAlarmHigh(self) -> "b":
        return self.alarm

    @dbus_property(access=PropertyAccess.READ)
    def WarningAlarmLow(self) -> "b":
        return False


class CriticalThreshold(_Threshold):
    def __init__(self, high):
        super().__init__("xyz.openbmc_project.Sensor.Threshold.Critical", high)

    def properties(self):
        return {"CriticalHigh": Variant("d", self.high),
                "CriticalLow": Variant("d", math.nan),
                "CriticalAlarmHigh": Variant("b", self.alarm),
                "CriticalAlarmLow": Variant("b", False)}

    @dbus_property(access=PropertyAccess.READ)
    def CriticalHigh(self) -> "d":
        return self.high

    @dbus_property(access=PropertyAccess.READ)
    def CriticalLow(self) -> "d":
        return math.nan

    @dbus_property(access=PropertyAccess.READ)
    def CriticalAlarmHigh(self) -> "b":
        return self.alarm

    @dbus_property(access=PropertyAccess.READ)
    def CriticalAlarmLow(self) -> "b":
        return False


class NonRecoverableThreshold(_Threshold):
    def __init__(self, high):
        super().__init__(NONRECOVERABLE_IFACE, high)

    def properties(self):
        return {"NonRecoverableHigh": Variant("d", self.high),
                "NonRecoverableLow": Variant("d", math.nan),
                "NonRecoverableAlarmHigh": Variant("b", self.alarm),
                "NonRecoverableAlarmLow": Variant("b", False)}

    @dbus_property(access=PropertyAccess.READ)
    def NonRecoverableHigh(self) -> "d":
        return self.high

    @dbus_property(access=PropertyAccess.READ)
    def NonRecoverableLow(self) -> "d":
        return math.nan

    @dbus_property(access=PropertyAccess.READ)
    def NonRecoverableAlarmHigh(self) -> "b":
        return self.alarm

    @dbus_property(access=PropertyAccess.READ)
    def NonRecoverableAlarmLow(self) -> "b":
        return False


class Associations(ServiceInterface):
    """Copy of the chassis associations of the source sensors, so the sensors
    show up under the same chassis in Redfish and the web interface."""

    def __init__(self):
        super().__init__(ASSOC_IFACE)
        self.assoc = []

    @dbus_property(access=PropertyAccess.READ)
    def Associations(self) -> "a(sss)":
        return self.assoc

    def update(self, assoc):
        if assoc != self.assoc:
            self.assoc = assoc
            self.emit_properties_changed({"Associations": assoc})


class SensorObjectManager(ServiceInterface):
    """org.freedesktop.DBus.ObjectManager on /xyz/openbmc_project/sensors.

    bmcweb reads the values of all the sensors of a service with one
    GetManagedObjects call on that path (the dbus-sensors daemons implement it).
    Without it the Redfish sensor list, which the web page shows, has no value
    for these sensors, while IPMI reads the properties one by one and works."""

    def __init__(self):
        super().__init__("org.freedesktop.DBus.ObjectManager")
        self.entries = []        # (path, sensor, associations, [threshold objects])

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        result = {}
        for path, sensor, assoc, thresholds in self.entries:
            interfaces = {
                VALUE_IFACE: {
                    "Value": Variant("d", sensor.value),
                    "Unit": Variant("s", UNIT_DEGREES_C),
                    "MaxValue": Variant("d", 127.0),
                    "MinValue": Variant("d", -128.0),
                },
                ASSOC_IFACE: {"Associations": Variant("a(sss)", assoc.assoc)},
            }
            for obj, _, _ in thresholds:
                interfaces[obj.interface_name] = obj.properties()
            result[path] = interfaces
        return result


async def call(bus, destination, path, interface, member, signature="", body=None):
    reply = await bus.call(Message(destination=destination, path=path,
                                   interface=interface, member=member,
                                   signature=signature, body=body or []))
    if reply.message_type == MessageType.ERROR:
        raise RuntimeError("%s.%s: %s" % (interface, member, reply.error_name))
    return reply.body


async def host_is_on(bus):
    try:
        body = await call(bus, CHASSIS_STATE[0], CHASSIS_STATE[1], PROPS, "Get",
                          "ss", [CHASSIS_STATE[2], CHASSIS_STATE[3]])
        return str(body[0].value).endswith(".On")
    except Exception:
        return True  # unknown: assume on


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def scan_sources():
    """Return {temp*_input path: (group, "device label")} of the PECI hwmon devices."""
    found = {}
    try:
        entries = sorted(os.listdir(HWMON_ROOT))
    except OSError:
        return found
    for entry in entries:
        hwmon = os.path.join(HWMON_ROOT, entry)
        name = read_text(os.path.join(hwmon, "name")) or ""
        if name.startswith("peci_cputemp"):
            group = "CPU"
        elif name.startswith("peci_dimmtemp"):
            group = "DIMM"
        else:
            continue
        try:
            files = sorted(os.listdir(hwmon))
        except OSError:
            continue
        for fname in files:
            match = TEMP_INPUT_RE.match(fname)
            if not match:
                continue
            label = read_text(os.path.join(hwmon, "temp%s_label" % match.group(1)))
            label = label or "temp" + match.group(1)
            if group == "CPU" and EXCLUDE_RE.search(label):
                continue
            found[os.path.join(hwmon, fname)] = (group, "%s %s" % (name, label))
    return found


def read_values(paths):
    """Read the temperatures in degrees C; a path that cannot be read is left out
    (the CPU is off or does not answer on PECI)."""
    values = {}
    for path in paths:
        text = read_text(path)
        try:
            values[path] = int(text) / 1000.0
        except (TypeError, ValueError):
            pass
    return values


async def read_assoc(bus, service, path):
    try:
        body = await call(bus, service, path, PROPS, "Get", "ss", [ASSOC_IFACE, "Associations"])
        return [tuple(a) for a in body[0].value]
    except Exception:
        return []


async def find_board_assoc(bus):
    """Chassis association of the board inventory item, the same endpoint the
    other sensors of the board (dbus-sensors) are associated with."""
    try:
        body = await call(bus, MAPPER, MAPPER_PATH, MAPPER, "GetSubTreePaths", "sias",
                          [INVENTORY_ROOT, 0, [BOARD_IFACE]])
        paths = sorted(body[0], key=lambda p: (p.count("/"), p))
        if paths:
            return [("chassis", "all_sensors", paths[0])]
    except Exception:
        pass
    return []


async def find_default_assoc(bus):
    """Chassis associations of an ADC sensor of this board.

    Fallback of find_board_assoc.  The ADC sensors belong to the same board, so
    their associations make the maximum sensors visible to IPMI and Redfish."""
    try:
        body = await call(bus, MAPPER, MAPPER_PATH, MAPPER, "GetSubTree", "sias",
                          [ADC_ROOT, 0, [ASSOC_IFACE]])
        for path, services in body[0].items():
            for service in services:
                assoc = await read_assoc(bus, service, path)
                if assoc:
                    return assoc
    except Exception:
        pass
    return []


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


async def watchdog_task(interval=15):
    """Ping the systemd watchdog from the event loop: a blocked or hung loop stops
    the pings and systemd restarts the service (WatchdogSec= in the unit)."""
    while True:
        sd_notify("WATCHDOG=1")
        await asyncio.sleep(interval)

async def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(levelname)s %(message)s")
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    sensors = {"CPU": TempSensor("CPU_MAX_TEMP"), "DIMM": TempSensor("DIMM_MAX_TEMP")}
    assocs = {"CPU": Associations(), "DIMM": Associations()}
    thresholds = {}
    for group, sensor in sensors.items():
        path = "%s/%s" % (SENSOR_ROOT, sensor.sensor_name)
        bus.export(path, sensor)
        bus.export(path, assocs[group])
        unc, uc, unr = THRESHOLDS[group]
        thresholds[group] = [
            (WarningThreshold(unc), "WarningAlarmHigh", "UNC"),
            (CriticalThreshold(uc), "CriticalAlarmHigh", "UC"),
            (NonRecoverableThreshold(unr), "NonRecoverableAlarmHigh", "UNR"),
        ]
        for obj, _, _ in thresholds[group]:
            bus.export(path, obj)
    manager = SensorObjectManager()
    for group, sensor in sensors.items():
        manager.entries.append(("%s/%s" % (SENSOR_ROOT, sensor.sensor_name), sensor,
                                assocs[group], [t[0] for t in thresholds[group]]))
    bus.export(SENSOR_BASE, manager)
    await bus.request_name(BUS_NAME)
    LOG.info("started, publishing CPU_MAX_TEMP and DIMM_MAX_TEMP")
    sd_notify("READY=1")
    asyncio.create_task(watchdog_task())

    known = None
    default_assoc = []
    while True:
        # sysfs reads are PECI transactions: keep them off the event loop
        sources = await asyncio.to_thread(scan_sources)
        names = {label: group for group, label in sources.values()}
        if names != known:
            known = names
            LOG.info("source temperatures: %d CPU, %d DIMM",
                     sum(1 for g in names.values() if g == "CPU"),
                     sum(1 for g in names.values() if g == "DIMM"))
            for name in sorted(names):
                LOG.info("  %-4s %s", names[name], name)
        readings = await asyncio.to_thread(read_values, list(sources))

        on = await host_is_on(bus)
        for group, sensor in sensors.items():
            values = [readings[path] for path, (g, _) in sources.items()
                      if g == group and path in readings
                      and not math.isnan(readings[path])]
            real = max(values) if values else math.nan
            if values:
                sensor.update(real)
            elif on:
                sensor.update(FAILSAFE_TEMP)   # no reading while the host is on: 60 % fans
            else:
                sensor.update(0.0)             # host off: no thermal load
            for obj, alarm_name, level in thresholds[group]:
                if obj.evaluate(sensor.sensor_name, real, alarm_name):
                    LOG.warning("%s %s %s (value %.1f, threshold %.1f)",
                                sensor.sensor_name, level,
                                "asserted" if obj.alarm else "cleared",
                                real, obj.high)
            if not assocs[group].assoc:
                if not default_assoc:
                    default_assoc = (await find_board_assoc(bus)
                                     or await find_default_assoc(bus))
                if default_assoc:
                    assocs[group].update(default_assoc)
        await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())
