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
        wanted = stored.get(props.get("Name"))
        if not wanted:
            continue
        for key, value in wanted.items():
            if key not in props or props[key] == value:
                continue
            await call(
                bus,
                service,
                path,
                PROPS,
                "Set",
                "ssv",
                [interface, key, Variant("d", float(value))],
            )
            LOG.info("applied %s %s.%s = %s (was %s)", interface.rsplit(".", 1)[-1],
                     props["Name"], key, value, props[key])
            changed += 1
    return changed


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
