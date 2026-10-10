#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Publish the board's BMC inventory and stable BMC UUID without RWFS writes."""

import asyncio
import re
import subprocess

from dbus_fast.aio import MessageBus
from dbus_fast.constants import BusType, NameFlag, PropertyAccess, RequestNameReply
from dbus_fast.service import ServiceInterface, dbus_property

SERVICE = "com.ctopai.CebGnrd.BmcInventory"
PATH = "/xyz/openbmc_project/inventory/system/chassis/motherboard/bmc"


def bmc_uuid():
    # The application ID must match Redfish Managers/bmc and IPMI Device GUID.
    # Use the installed systemd tool, avoiding architecture-specific C ABI code.
    text = subprocess.check_output(
        ["systemd-id128", "--app-specific=e0e17376646147daa50cd0cc64124578", "machine-id"],
        stdin=subprocess.DEVNULL,
        text=True,
        timeout=5,
    ).strip().lower()
    if not re.fullmatch(r"[0-9a-f]{32}", text) or text == "0" * 32:
        raise RuntimeError("systemd-id128 returned an invalid BMC UUID")
    return "-".join((text[:8], text[8:12], text[12:16], text[16:20], text[20:]))


class Bmc(ServiceInterface):
    def __init__(self):
        super().__init__("xyz.openbmc_project.Inventory.Item.Bmc")


class Item(ServiceInterface):
    def __init__(self):
        super().__init__("xyz.openbmc_project.Inventory.Item")

    @dbus_property(access=PropertyAccess.READ)
    def Present(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def PrettyName(self) -> "s":
        return "CEB-GNRD BMC"


class Uuid(ServiceInterface):
    def __init__(self, value):
        super().__init__("xyz.openbmc_project.Common.UUID")
        self.value = value

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.value


async def main():
    value = bmc_uuid()
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    for interface in (Bmc(), Item(), Uuid(value)):
        bus.export(PATH, interface)
    reply = await bus.request_name(SERVICE, NameFlag.DO_NOT_QUEUE)
    if reply != RequestNameReply.PRIMARY_OWNER:
        raise RuntimeError(f"Unable to own {SERVICE}: {reply}")
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(main())
