#!/usr/bin/env python3
"""CEB-GNRD CPU / DIMM maximum temperature sensors.

The PECI based IntelCPUSensor daemon publishes one temperature sensor per CPU
core and per DIMM.  Fan control only needs the hottest value of each group, so
this service publishes exactly two D-Bus sensors:

    /xyz/openbmc_project/sensors/temperature/CPU_MAX_TEMP
    /xyz/openbmc_project/sensors/temperature/DIMM_MAX_TEMP

which phosphor-pid-control uses as its inputs (see ceb-gnrd.json).

The source sensors are found by service name (xyz.openbmc_project.IntelCPUSensor)
and by name pattern:
  * DIMM : the sensor name contains "dimm"
  * CPU  : every other temperature sensor of that service, except margin style
           readings (DTS) and the Tcontrol / Tthrottle / Tjmax thresholds

Upper thresholds (non-critical / critical / non-recoverable) are published on the
Warning / Critical / HardShutdown threshold interfaces, so phosphor-sel-logger
records the alarms and IPMI shows UNC / UC / UNR.

When the host is off the value is 0 (no thermal load); when the host is on but
no source sensor is readable the value is NaN so that the fan controller falls
back to its fail-safe speed.

All discovered names and their group are written to the journal whenever the
set changes:  journalctl -u ceb-gnrd-temp-max
"""

import asyncio
import logging
import math
import re
import sys

from dbus_fast import BusType, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property

LOG = logging.getLogger("ceb-gnrd-temp-max")

BUS_NAME = "xyz.openbmc_project.CebGnrd.TempMax"
SENSOR_ROOT = "/xyz/openbmc_project/sensors/temperature"
SOURCE_SERVICE = "xyz.openbmc_project.IntelCPUSensor"
VALUE_IFACE = "xyz.openbmc_project.Sensor.Value"
UNIT_DEGREES_C = "xyz.openbmc_project.Sensor.Value.Unit.DegreesC"
ASSOC_IFACE = "xyz.openbmc_project.Association.Definitions"

MAPPER = "xyz.openbmc_project.ObjectMapper"
MAPPER_PATH = "/xyz/openbmc_project/object_mapper"
PROPS = "org.freedesktop.DBus.Properties"
CHASSIS_STATE = ("xyz.openbmc_project.State.Chassis",
                 "/xyz/openbmc_project/state/chassis0",
                 "xyz.openbmc_project.State.Chassis", "CurrentPowerState")

DIMM_RE = re.compile(r"dimm", re.IGNORECASE)
EXCLUDE_RE = re.compile(r"dts|tcontrol|tthrottle|tjmax|margin", re.IGNORECASE)

POLL_SECONDS = 2

# Upper thresholds in degrees C: (non-critical UNC, critical UC, non-recoverable UNR)
THRESHOLDS = {
    "CPU": (90.0, 98.0, 105.0),
    "DIMM": (80.0, 85.0, 95.0),
}


class TempSensor(ServiceInterface):
    def __init__(self, name):
        super().__init__(VALUE_IFACE)
        self.name = name
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
        self.high = high
        self.alarm = False

    def evaluate(self, value, alarm_name):
        alarm = (not math.isnan(value)) and value >= self.high
        if alarm != self.alarm:
            self.alarm = alarm
            self.emit_properties_changed({alarm_name: alarm})
            return True
        return False


class WarningThreshold(_Threshold):
    def __init__(self, high):
        super().__init__("xyz.openbmc_project.Sensor.Threshold.Warning", high)

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


class HardShutdownThreshold(_Threshold):
    def __init__(self, high):
        super().__init__("xyz.openbmc_project.Sensor.Threshold.HardShutdown", high)

    @dbus_property(access=PropertyAccess.READ)
    def HardShutdownHigh(self) -> "d":
        return self.high

    @dbus_property(access=PropertyAccess.READ)
    def HardShutdownLow(self) -> "d":
        return math.nan

    @dbus_property(access=PropertyAccess.READ)
    def HardShutdownAlarmHigh(self) -> "b":
        return self.alarm

    @dbus_property(access=PropertyAccess.READ)
    def HardShutdownAlarmLow(self) -> "b":
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
        return True  # unknown: assume on so that a missing sensor is fail-safe


async def find_sources(bus):
    """Return {sensor path: (service, group)} for all IntelCPUSensor temperatures."""
    body = await call(bus, MAPPER, MAPPER_PATH, MAPPER, "GetSubTree", "sias",
                      [SENSOR_ROOT, 0, [VALUE_IFACE]])
    found = {}
    for path, services in body[0].items():
        if SOURCE_SERVICE not in services:
            continue
        name = path.rsplit("/", 1)[-1]
        if DIMM_RE.search(name):
            found[path] = (SOURCE_SERVICE, "DIMM")
        elif not EXCLUDE_RE.search(name):
            found[path] = (SOURCE_SERVICE, "CPU")
    return found


async def read_value(bus, service, path):
    body = await call(bus, service, path, PROPS, "Get", "ss", [VALUE_IFACE, "Value"])
    return float(body[0].value)


async def read_assoc(bus, service, path):
    try:
        body = await call(bus, service, path, PROPS, "Get", "ss", [ASSOC_IFACE, "Associations"])
        return [tuple(a) for a in body[0].value]
    except Exception:
        return []


async def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(levelname)s %(message)s")
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    sensors = {"CPU": TempSensor("CPU_MAX_TEMP"), "DIMM": TempSensor("DIMM_MAX_TEMP")}
    assocs = {"CPU": Associations(), "DIMM": Associations()}
    thresholds = {}
    for group, sensor in sensors.items():
        path = "%s/%s" % (SENSOR_ROOT, sensor.name)
        bus.export(path, sensor)
        bus.export(path, assocs[group])
        unc, uc, unr = THRESHOLDS[group]
        thresholds[group] = [
            (WarningThreshold(unc), "WarningAlarmHigh", "UNC"),
            (CriticalThreshold(uc), "CriticalAlarmHigh", "UC"),
            (HardShutdownThreshold(unr), "HardShutdownAlarmHigh", "UNR"),
        ]
        for obj, _, _ in thresholds[group]:
            bus.export(path, obj)
    await bus.request_name(BUS_NAME)
    LOG.info("started, publishing CPU_MAX_TEMP and DIMM_MAX_TEMP")

    known = None
    while True:
        try:
            sources = await find_sources(bus)
        except Exception as exc:
            LOG.warning("cannot list temperature sensors: %s", exc)
            sources = {}
        names = {p.rsplit("/", 1)[-1]: g for p, (_, g) in sources.items()}
        if names != known:
            known = names
            LOG.info("source sensors: %d CPU, %d DIMM",
                     sum(1 for g in names.values() if g == "CPU"),
                     sum(1 for g in names.values() if g == "DIMM"))
            for name in sorted(names):
                LOG.info("  %-4s %s", names[name], name)

        on = await host_is_on(bus)
        for group, sensor in sensors.items():
            values = []
            assoc = []
            for path, (service, g) in sources.items():
                if g != group:
                    continue
                try:
                    value = await read_value(bus, service, path)
                except Exception:
                    continue
                if math.isnan(value):
                    continue
                values.append(value)
                if not assoc:
                    assoc = await read_assoc(bus, service, path)
            if values:
                sensor.update(max(values))
            elif on:
                sensor.update(math.nan)   # no reading while the host is on: fail-safe
            else:
                sensor.update(0.0)        # host off: no thermal load
            for obj, alarm_name, level in thresholds[group]:
                if obj.evaluate(sensor.value, alarm_name):
                    LOG.warning("%s %s %s (value %.1f, threshold %.1f)",
                                sensor.name, level,
                                "asserted" if obj.alarm else "cleared",
                                sensor.value, obj.high)
            if assoc:
                assocs[group].update(assoc)
        await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())
