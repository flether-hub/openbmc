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
  service  com.ctopai.CebGnrd.FanSettings
  object   /xyz/openbmc_project/ceb_gnrd/fan_settings
  property Persist (b, read/write)
  method   Save()  snapshot the current Entity-Manager values (or delete the
                   stored file when Persist is false)
  method   ApplyFan<0..5|All><Adaptive|Fixed20..100><Keep|Forget>() -> b
                   atomic target/mode/duty/persistence operation (web page)
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
import math
import os
import socket
import sys

from dbus_fast import BusType, DBusError, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property, method

LOG = logging.getLogger("ceb-gnrd-fan-settings")


class JournalFormatter(logging.Formatter):
    """Keep each Python record's actual priority in the systemd journal."""
    def format(self, record):
        priority = (2 if record.levelno >= logging.CRITICAL else
                    3 if record.levelno >= logging.ERROR else
                    4 if record.levelno >= logging.WARNING else
                    6 if record.levelno >= logging.INFO else 7)
        return "<%d>%s" % (priority, super().format(record))

BUS_NAME = "com.ctopai.CebGnrd.FanSettings"
# The object path stays under /xyz: the bmcweb D-Bus REST API (used by the web page)
# only serves object paths that start with /xyz or /org.
OBJ_PATH = "/xyz/openbmc_project/ceb_gnrd/fan_settings"
IFACE = "com.ctopai.CebGnrd.FanSettings"

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
# Entity-Manager Pid objects.  They must not be called SYS_FAN<n>: the AspeedFan
# object has that name, and both would share one D-Bus path (writes then fail).
PID_NAMES = ["Fan%d Control" % i for i in range(FAN_COUNT)]
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
DBUS_TIMEOUT_SECONDS = 5


async def call(bus, destination, path, interface, member, signature="", body=None):
    reply = await asyncio.wait_for(
        bus.call(Message(destination=destination, path=path, interface=interface,
                         member=member, signature=signature, body=body or [])),
        timeout=DBUS_TIMEOUT_SECONDS,
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


async def snapshot_config(bus, interface, requested):
    """Validate every target and capture all old values before any write."""
    keys = {key for values in requested.values() for key in values}
    current = await read_config(bus, interface, keys)
    snapshot = {}
    for name, wanted in requested.items():
        if name not in current or any(key not in current[name] for key in wanted):
            raise RuntimeError("missing configuration/property: %s" % name)
        snapshot[name] = {key: current[name][key] for key in wanted}
    return snapshot


async def write_config(bus, interface, stored):
    """Set stored values on the matching objects; return the number changed."""
    changed = 0
    found = set()
    for service, path in await find_objects(bus, interface):
        body = await call(bus, service, path, PROPS, "GetAll", "s", [interface])
        props = {k: v.value for k, v in body[0].items()}
        signatures = {k: v.signature for k, v in body[0].items()}
        wanted = stored.get(props.get("Name"))
        if not wanted:
            continue
        found.add(props["Name"])
        for key, value in wanted.items():
            if key not in props:
                raise RuntimeError("missing property %s.%s" % (props["Name"], key))
            if props[key] == value:
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
    missing = set(stored) - found
    if missing:
        raise RuntimeError("missing configuration: %s" % ", ".join(sorted(missing)))
    return changed


async def refresh_control(bus):
    """Rebuild controllers even if Entity-Manager suppressed its change signal.

    Its property setter can update the value and then return an error while
    saving JSON. Readback alone does not prove that swampd loaded the value.
    RestartUnit queues a restart; it does not wait for sensors to become ready.
    """
    await call(bus, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
               "org.freedesktop.systemd1.Manager", "RestartUnit", "ss",
               ["phosphor-pid-control.service", "replace"])


async def finish_control_refresh(bus, iface):
    """Only clear the retry flag after systemd accepted the restart."""
    iface.refresh_pending = True
    await refresh_control(bus)
    iface.refresh_pending = False


async def restore_pending_configuration(bus, iface):
    """Retry a failed rollback before accepting another setting operation."""
    snapshot = iface.rollback_pending
    if snapshot is None:
        return
    iface.refresh_pending = True
    await write_config(bus, PID_IFACE, snapshot["controllers"])
    await write_config(bus, ZONE_IFACE, snapshot["zones"])
    await finish_control_refresh(bus, iface)
    iface.rollback_pending = None


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
    path = "%s/PWM%d" % (PWM_ROOT, index)
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
        self.operation_lock = asyncio.Lock()
        self.refresh_pending = False
        self.rollback_pending = None

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

    # Legacy persistence controls. The current web page uses a single ApplyFan*
    # call containing target, mode, duty and persistence.
    @method()
    async def KeepSettings(self) -> "b":
        """Keep the current fan settings after a BMC reboot."""
        async with self.operation_lock:
            return await self._set_persistence(True)

    @method()
    async def ForgetSettings(self) -> "b":
        """Do not keep the fan settings: a BMC reboot returns to adaptive mode."""
        async with self.operation_lock:
            return await self._set_persistence(False)

    async def _set_persistence(self, value):
        previous = self.persist
        self.persist = value
        if not await self._do_save():
            self.persist = previous
            return False
        self.emit_properties_changed({"Persist": value})
        return True

    @method()
    async def GetFans(self) -> "ay":
        """Fan status for the IPMI OEM Get command (see the module docstring)."""
        async with self.operation_lock:
            return await self._get_fans()

    async def _get_fans(self):
        try:
            pids = await read_config(self.bus, PID_IFACE, PID_KEYS)
            limits = []
            # Mode is authoritative only when all six controller limits are
            # readable. A partial configuration must not look like adaptive mode.
            for name in PID_NAMES:
                props = pids.get(name, {})
                if any(key not in props for key in PID_KEYS):
                    raise RuntimeError("missing configuration/property: %s" % name)
                low, high = (props[key] for key in PID_KEYS)
                if any(isinstance(value, bool) or not isinstance(value, (int, float))
                       or not math.isfinite(value) for value in (low, high)):
                    raise RuntimeError("invalid fan output limits: %s" % name)
                if not 0 <= low <= high <= 100:
                    raise RuntimeError("fan output limits out of range: %s" % name)
                limits.append((low, high))
        except Exception as exc:
            LOG.error("GetFans: cannot read the fan controllers: %s", exc)
            raise DBusError(IFACE + ".ConfigurationUnavailable",
                            "Fan controller configuration is unavailable: %s" % exc) from exc
        rpms = await read_fan_rpms(self.bus)
        out = [1 if self.persist else 0]
        for index, name in enumerate(FAN_NAMES):
            low, high = limits[index]
            fixed = low == high
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
        return await self.apply_fan(fan, mode, duty, persist)

    async def apply_fan(self, fan, mode, duty, persist) -> bool:
        async with self.operation_lock:
            return await self._apply_fan(fan, mode, duty, persist)

    async def _apply_fan(self, fan, mode, duty, persist) -> bool:
        if fan != 0xFF and fan >= FAN_COUNT:
            LOG.warning("SetFan: invalid fan %d", fan)
            return False
        if mode not in (0, 1) or persist not in (0, 1):
            LOG.warning("SetFan: invalid mode %d or persist %d", mode, persist)
            return False
        if mode == 1 and not (FIXED_MIN_DUTY <= duty <= 100):
            LOG.warning("SetFan: invalid duty %d (valid %d..100)", duty, FIXED_MIN_DUTY)
            return False
        names = PID_NAMES if fan == 0xFF else [PID_NAMES[fan]]
        low, high = (float(duty), float(duty)) if mode == 1 else (ADAPTIVE_MIN, ADAPTIVE_MAX)
        requested = {name: {"OutLimitMin": low, "OutLimitMax": high} for name in names}
        zone_requested = {ZONE_NAME: {"MinThermalOutput": ADAPTIVE_MIN}}
        previous_persist = self.persist
        snapshot = None
        try:
            await restore_pending_configuration(self.bus, self)
            snapshot = {
                "controllers": await snapshot_config(self.bus, PID_IFACE, requested),
                "zones": await snapshot_config(self.bus, ZONE_IFACE, zone_requested),
            }
            # Keep the rollback target until configuration, restart request and
            # persistence have all succeeded. No partial update is a success.
            self.rollback_pending = snapshot
            self.refresh_pending = True
            changed = await write_config(self.bus, PID_IFACE, requested)
            # Fixed duties belong to the individual fan controllers. A shared
            # fixed floor would also constrain fans returned to adaptive mode.
            changed += await write_config(self.bus, ZONE_IFACE, zone_requested)
            await finish_control_refresh(self.bus, self)
            self.persist = bool(persist)
            if not await self._do_save():
                raise RuntimeError("cannot persist fan settings")
            self.rollback_pending = None
        except Exception as exc:
            self.persist = previous_persist
            LOG.error("SetFan failed: %s", exc)
            if snapshot is not None:
                try:
                    await restore_pending_configuration(self.bus, self)
                except Exception as rollback_error:
                    # Maintenance retries this exact snapshot, even when the
                    # user had not enabled persistent settings.
                    LOG.error("Fan setting rollback pending: %s", rollback_error)
            return False
        LOG.info("SetFan: fan %s mode %s duty %d persist %d (%d value(s) changed)",
                 "all" if fan == 0xFF else fan, "fixed" if mode else "adaptive",
                 duty, persist, changed)
        self.emit_properties_changed({"Persist": self.persist})
        return True

    async def do_save(self) -> bool:
        async with self.operation_lock:
            return await self._do_save()

    async def _do_save(self) -> bool:
        try:
            if not self.persist:
                delete_state()
                LOG.info("Save: persistence off, the next BMC reboot returns to adaptive mode")
                return True
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


def _web_apply_method(name, fan, mode, duty, persist):
    """Each REST method carries its complete operation in its member name.

    dbus-fast discovers the decorated members when ServiceInterface is created.
    No selected target or pending persistence choice is shared between clients.
    """
    async def apply(self) -> "b":
        return await self.apply_fan(fan, mode, duty, persist)
    return method(name=name)(apply)


for _fan in range(FAN_COUNT + 1):
    _target = "All" if _fan == FAN_COUNT else str(_fan)
    for _mode, _duty in [(0, 0)] + [(1, d) for d in (20, 40, 60, 80, 100)]:
        for _persist in (0, 1):
            _name = "ApplyFan%s%s%s" % (
                _target, "Adaptive" if _mode == 0 else "Fixed%d" % _duty,
                "Keep" if _persist else "Forget")
            setattr(FanSettings, _name, _web_apply_method(
                _name, 0xFF if _fan == FAN_COUNT else _fan,
                _mode, _duty, _persist))


async def apply_stored(bus, state, iface):
    pending = iface.refresh_pending
    # Preserve retry intent if any write or restart fails after a partial
    # restore. Equality on the next read does not prove swampd reloaded it.
    iface.refresh_pending = True
    changed = await write_config(bus, PID_IFACE, state.get("controllers", {}))
    # Migrate snapshots from versions that saved the all-fan fixed duty as
    # the zone floor. Keep the requested individual controller limits.
    changed += await write_config(bus, ZONE_IFACE,
                                  {ZONE_NAME: {"MinThermalOutput": ADAPTIVE_MIN}})
    if changed or pending:
        await finish_control_refresh(bus, iface)
    else:
        iface.refresh_pending = False
    return changed


async def maintain(bus, iface):
    """Apply the stored settings at boot and keep them applied."""
    first = True
    while True:
        try:
            async with iface.operation_lock:
                await restore_pending_configuration(bus, iface)
                state = load_state()
                if state and state.get("persist"):
                    # Read under the lock so a completed user operation takes
                    # precedence over an older persisted snapshot.
                    changed = 0
                    if not iface.persist:
                        iface.persist = True
                        iface.emit_properties_changed({"Persist": True})
                    changed = await apply_stored(bus, state, iface)
                    if first:
                        LOG.info("restored persisted fan settings (%d value(s) changed)", changed)
                        first = False
                else:
                    if iface.refresh_pending:
                        await finish_control_refresh(bus, iface)
                    if first:
                        LOG.info("no persisted fan settings, using the adaptive defaults")
                        first = False
        except Exception as exc:
            LOG.warning("waiting to recover fan configuration/control: %s", exc)
            await asyncio.sleep(APPLY_RETRY_SECONDS)
            continue
        await asyncio.sleep(CHECK_INTERVAL_SECONDS)


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
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(levelname)s %(message)s")
    for handler in logging.getLogger().handlers:
        handler.setFormatter(JournalFormatter("%(levelname)s %(message)s"))
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    iface = FanSettings(bus)
    bus.export(OBJ_PATH, iface)
    await bus.request_name(BUS_NAME)
    LOG.info("started, D-Bus service %s", BUS_NAME)
    sd_notify("READY=1")
    asyncio.create_task(watchdog_task())
    await maintain(bus, iface)


if __name__ == "__main__":
    asyncio.run(main())
