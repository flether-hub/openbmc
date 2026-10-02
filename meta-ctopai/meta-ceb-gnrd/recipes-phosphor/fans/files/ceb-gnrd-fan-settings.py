#!/usr/bin/env python3
"""CEB-GNRD fan settings persistence service.

The fan control web page changes the Entity-Manager Pid / Pid.Zone properties
(through bmcweb).  Those changes only live in RAM, so after a BMC reboot the
adaptive defaults from the Entity-Manager configuration apply again.

This service lets the user choose to keep the settings:

  * Persist = false: nothing is stored; a BMC reboot returns to adaptive mode.
  * Persist = true:  the current settings are saved under /var/lib/ceb-gnrd
    (read-write flash, survives power cycles) and re-applied after every boot.

D-Bus API (reachable through the bmcweb D-Bus REST interface):
  service  xyz.openbmc_project.CebGnrd.FanSettings
  object   /xyz/openbmc_project/ceb_gnrd/fan_settings
  property Persist (b, read/write)
  method   Save()  snapshot the current Entity-Manager values (or delete the
                   stored file when Persist is false)
  method   KeepSettings() / ForgetSettings()  set Persist and save (no arguments,
                   for the web page)
  method   GetFans() -> ay  status of the six fans (used by the IPMI OEM command)
  method   SetFan(y fan, y mode, y duty, y persist) -> b   change one fan or all fans
                   (used by the IPMI OEM command)

IPMI OEM commands (netfn 0x30, implemented by the ceb-gnrd-ipmi-fan library, which
only forwards to the two methods above):
  0x01  Get   response: byte 0 = keep settings after reboot (0/1), then 4 bytes per
              fan SYS_FAN0..SYS_FAN5: mode (0 adaptive, 1 fixed), duty in percent
              (0xFF unknown), speed in RPM (low byte, high byte)
  0x02  Set   request: fan (0..5, 0xFF = all), mode (0 adaptive, 1 fixed), duty
              (10..100, used for fixed mode), persist (0/1)

Everything is logged to the journal: journalctl -u ceb-gnrd-fan-settings
"""

import asyncio
import json
import logging
import os
import sys

from dbus_fast import BusType, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property, method

LOG = logging.getLogger("ceb-gnrd-fan-settings")

BUS_NAME = "xyz.openbmc_project.CebGnrd.FanSettings"
OBJ_PATH = "/xyz/openbmc_project/ceb_gnrd/fan_settings"
IFACE = "xyz.openbmc_project.CebGnrd.FanSettings"

STATE_DIR = "/var/lib/ceb-gnrd"
STATE_FILE = os.path.join(STATE_DIR, "fan-settings.json")

MAPPER = "xyz.openbmc_project.ObjectMapper"
MAPPER_PATH = "/xyz/openbmc_project/object_mapper"
PROPS = "org.freedesktop.DBus.Properties"
PID_IFACE = "xyz.openbmc_project.Configuration.Pid"
ZONE_IFACE = "xyz.openbmc_project.Configuration.Pid.Zone"

# Property names persisted for each configuration type.
FAN_COUNT = 6
FAN_NAMES = ["SYS_FAN%d" % i for i in range(FAN_COUNT)]
FAN_TACH_ROOT = "/xyz/openbmc_project/sensors/fan_tach"
PWM_ROOT = "/xyz/openbmc_project/control/fanpwm"
VALUE_IFACE = "xyz.openbmc_project.Sensor.Value"
FANPWM_IFACE = "xyz.openbmc_project.Control.FanPwm"
ZONE_NAME = "Zone 1"
# Adaptive mode: the fan controllers use these limits (same as ceb-gnrd.json).
ADAPTIVE_MIN = 30.0
ADAPTIVE_MAX = 100.0
FIXED_MIN_DUTY = 10
PID_KEYS = ("OutLimitMin", "OutLimitMax")
ZONE_KEYS = ("MinThermalOutput",)

APPLY_RETRY_SECONDS = 10
CHECK_INTERVAL_SECONDS = 30


async def call(bus, destination, path, interface, member, signature="", body=None):
    reply = await bus.call(
        Message(
            destination=destination,
            path=path,
            interface=interface,
            member=member,
            signature=signature,
            body=body or [],
        )
    )
    if reply.message_type == MessageType.ERROR:
        raise RuntimeError("%s.%s failed: %s %s" % (interface, member, reply.error_name, reply.body))
    return reply.body


async def find_objects(bus, interface):
    """Return [(service, path)] of Entity-Manager objects implementing interface."""
    body = await call(
        bus,
        MAPPER,
        MAPPER_PATH,
        MAPPER,
        "GetSubTree",
        "sias",
        ["/xyz/openbmc_project/inventory", 0, [interface]],
    )
    found = []
    for path, services in body[0].items():
        for service in services:
            found.append((service, path))
    return found


async def read_config(bus, interface, keys):
    """Return {Name: {key: value}} for all objects of one configuration type."""
    result = {}
    for service, path in await find_objects(bus, interface):
        body = await call(bus, service, path, PROPS, "GetAll", "s", [interface])
        props = {k: v.value for k, v in body[0].items()}
        name = props.get("Name")
        if name is None:
            continue
        result[name] = {k: props[k] for k in keys if k in props}
    return result


async def write_config(bus, interface, stored):
    """Set stored values on the matching objects; return the number changed."""
    changed = 0
    for service, path in await find_objects(bus, interface):
        body = await call(bus, service, path, PROPS, "GetAll", "s", [interface])
        props = {k: v.value for k, v in body[0].items()}
        signatures = {k: v.signature for k, v in body[0].items()}
        wanted = stored.get(props.get("Name"))
        if not wanted:
            continue
        for key, value in wanted.items():
            if key not in props or props[key] == value:
                continue
            # Write with the type the property already has (Entity-Manager
            # rejects a different one with InvalidArgs).
            signature = signatures[key]
            send = float(value) if signature == "d" else int(value)
            try:
                await call(
                    bus,
                    service,
                    path,
                    PROPS,
                    "Set",
                    "ssv",
                    [interface, key, Variant(signature, send)],
                )
            except RuntimeError as exc:
                # Entity-Manager stores the new value and then reports InvalidArgs
                # when it cannot save its own JSON copy.  The value is what
                # phosphor-pid-control uses, so read it back before giving up.
                now = await call(bus, service, path, PROPS, "Get", "ss", [interface, key])
                if now[0].value != send:
                    raise
                LOG.warning("Set %s.%s reported an error but the value is applied: %s",
                            props["Name"], key, exc)
            LOG.info("applied %s %s.%s = %s (was %s)", interface.rsplit(".", 1)[-1],
                     props["Name"], key, value, props[key])
            changed += 1
    return changed


async def read_fan_rpms(bus):
    """Return {sensor name: rpm} of the fan tach sensors."""
    rpms = {}
    try:
        body = await call(bus, MAPPER, MAPPER_PATH, MAPPER, "GetSubTree", "sias",
                          [FAN_TACH_ROOT, 0, [VALUE_IFACE]])
    except Exception:
        return rpms
    for path, services in body[0].items():
        for service in services:
            try:
                value = await call(bus, service, path, PROPS, "Get", "ss", [VALUE_IFACE, "Value"])
                rpm = float(value[0].value)
                if rpm == rpm:  # not NaN
                    rpms[path.rsplit("/", 1)[-1]] = int(round(rpm))
            except Exception:
                pass
    return rpms


async def read_pwm_percent(bus, index):
    """Current PWM output of fan index in percent, None when it cannot be read."""
    path = "%s/PWM%d" % (PWM_ROOT, index + 1)
    try:
        body = await call(bus, MAPPER, MAPPER_PATH, MAPPER, "GetObject", "sas", [path, [FANPWM_IFACE]])
        service = next(iter(body[0]))
        value = await call(bus, service, path, PROPS, "Get", "ss", [FANPWM_IFACE, "Target"])
        return max(0, min(100, int(round(float(value[0].value)))))
    except Exception:
        return None


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        LOG.error("cannot read %s: %s", STATE_FILE, exc)
        return None


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, STATE_FILE)


def delete_state():
    try:
        os.remove(STATE_FILE)
        LOG.info("removed %s", STATE_FILE)
    except FileNotFoundError:
        pass


class FanSettings(ServiceInterface):
    def __init__(self, bus):
        super().__init__(IFACE)
        self.bus = bus
        self.persist = False

    @dbus_property(access=PropertyAccess.READWRITE)
    def Persist(self) -> "b":
        return self.persist

    @Persist.setter
    def Persist(self, value: "b"):
        self.persist = bool(value)
        LOG.info("Persist set to %s", self.persist)
        self.emit_properties_changed({"Persist": self.persist})

    @method()
    async def Save(self) -> "b":
        """Store the current fan settings, or forget them when Persist is false."""
        return await self.do_save()

    # The web page (bmcweb D-Bus REST) cannot pass scalar arguments, so these two
    # methods have none: the page sets the limits through Redfish, then calls one.
    @method()
    async def KeepSettings(self) -> "b":
        """Keep the current fan settings after a BMC reboot."""
        self.persist = True
        self.emit_properties_changed({"Persist": True})
        return await self.do_save()

    @method()
    async def ForgetSettings(self) -> "b":
        """Do not keep the fan settings: a BMC reboot returns to adaptive mode."""
        self.persist = False
        self.emit_properties_changed({"Persist": False})
        return await self.do_save()

    @method()
    async def GetFans(self) -> "ay":
        """Fan status for the IPMI OEM Get command (see the module docstring)."""
        try:
            pids = await read_config(self.bus, PID_IFACE, PID_KEYS)
        except Exception as exc:
            LOG.error("GetFans: cannot read the fan controllers: %s", exc)
            pids = {}
        rpms = await read_fan_rpms(self.bus)
        out = [1 if self.persist else 0]
        for index, name in enumerate(FAN_NAMES):
            limits = pids.get(name, {})
            low = limits.get("OutLimitMin")
            high = limits.get("OutLimitMax")
            fixed = low is not None and high is not None and low == high
            if fixed:
                duty = int(round(high))
            else:
                pwm = await read_pwm_percent(self.bus, index)
                duty = 0xFF if pwm is None else pwm
            rpm = max(0, min(0xFFFF, rpms.get(name, 0)))
            out += [1 if fixed else 0, duty, rpm & 0xFF, rpm >> 8]
        # dbus-fast marshals "ay" from bytes, not from a list of ints
        return bytes(out)

    @method()
    async def SetFan(self, fan: "y", mode: "y", duty: "y", persist: "y") -> "b":
        """Set one fan (0..5) or all fans (0xFF) to adaptive (0) or fixed (1) mode."""
        if fan != 0xFF and fan >= FAN_COUNT:
            LOG.warning("SetFan: invalid fan %d", fan)
            return False
        if mode not in (0, 1) or persist not in (0, 1):
            LOG.warning("SetFan: invalid mode %d or persist %d", mode, persist)
            return False
        if mode == 1 and not (FIXED_MIN_DUTY <= duty <= 100):
            LOG.warning("SetFan: invalid duty %d (valid %d..100)", duty, FIXED_MIN_DUTY)
            return False
        names = FAN_NAMES if fan == 0xFF else [FAN_NAMES[fan]]
        low, high = (float(duty), float(duty)) if mode == 1 else (ADAPTIVE_MIN, ADAPTIVE_MAX)
        try:
            changed = await write_config(
                self.bus, PID_IFACE,
                {name: {"OutLimitMin": low, "OutLimitMax": high} for name in names})
            if fan == 0xFF:
                await write_config(self.bus, ZONE_IFACE,
                                   {ZONE_NAME: {"MinThermalOutput": low}})
        except Exception as exc:
            LOG.error("SetFan failed: %s", exc)
            return False
        LOG.info("SetFan: fan %s mode %s duty %d persist %d (%d value(s) changed)",
                 "all" if fan == 0xFF else fan, "fixed" if mode else "adaptive",
                 duty, persist, changed)
        self.persist = bool(persist)
        self.emit_properties_changed({"Persist": self.persist})
        return await self.do_save()

    async def do_save(self) -> bool:
        if not self.persist:
            delete_state()
            LOG.info("Save: persistence off, the next BMC reboot returns to adaptive mode")
            return True
        try:
            state = {
                "persist": True,
                "controllers": await read_config(self.bus, PID_IFACE, PID_KEYS),
                "zones": await read_config(self.bus, ZONE_IFACE, ZONE_KEYS),
            }
            if not state["controllers"] and not state["zones"]:
                LOG.error("Save: no Entity-Manager fan configuration found, nothing stored")
                return False
            save_state(state)
            LOG.info("Save: stored %d controller(s) and %d zone(s) in %s",
                     len(state["controllers"]), len(state["zones"]), STATE_FILE)
            return True
        except Exception as exc:  # report every failure to the caller and the journal
            LOG.error("Save failed: %s", exc)
            return False


async def apply_stored(bus, state):
    changed = await write_config(bus, PID_IFACE, state.get("controllers", {}))
    changed += await write_config(bus, ZONE_IFACE, state.get("zones", {}))
    return changed


async def maintain(bus, iface):
    """Apply the stored settings at boot and keep them applied."""
    first = True
    while True:
        state = load_state()
        if state and state.get("persist"):
            iface.persist = True
            try:
                changed = await apply_stored(bus, state)
                if first:
                    LOG.info("restored persisted fan settings (%d value(s) changed)", changed)
                    first = False
            except Exception as exc:
                LOG.warning("waiting for Entity-Manager fan configuration: %s", exc)
                await asyncio.sleep(APPLY_RETRY_SECONDS)
                continue
        elif first:
            LOG.info("no persisted fan settings, using the adaptive defaults")
            first = False
        await asyncio.sleep(CHECK_INTERVAL_SECONDS)


async def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(levelname)s %(message)s")
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    iface = FanSettings(bus)
    bus.export(OBJ_PATH, iface)
    await bus.request_name(BUS_NAME)
    LOG.info("started, D-Bus service %s", BUS_NAME)
    await maintain(bus, iface)


if __name__ == "__main__":
    asyncio.run(main())
