#!/usr/bin/env python3
"""CEB-GNRD host boot progress from BIOS POST codes.

Nothing in OpenBMC turns POST codes into xyz.openbmc_project.State.Boot.Progress
(phosphor-host-postd only publishes the raw code, phosphor-post-code-manager only
records the history), and this host does not report its boot progress itself.
This service watches the POST codes from phosphor-host-postd
(xyz.openbmc_project.State.Boot.Raw, port 0x80) and publishes BootProgress /
BootProgressLastUpdate on /xyz/openbmc_project/state/host0, where the IPMI
Boot_Progress sensor and the web discrete sensor table read it.

Checkpoint meanings and stages use the same AMI Aptio V reference catalog
as the POST-code log page. Exact error definitions take priority over broad
ranges. OEM, reserved and unknown codes do not advance boot progress; the
raw code is retained and the Web page reports that no definition matched.
The old guessed Intel MRC overlap at 0xB0-0xDF is intentionally removed:
the supplied reference defines B0/B1 as runtime mapping and D0-DD as errors.
ACPI/ASL codes reuse some POST values. After a boot handoff, these reused
values do not regress the coarse stage to CPU/memory initialization. The
Web explanation shows both documented meanings where context is ambiguous.
No POST code is proof that the OS is running. BIOS POST complete means
OSStart; host power off or a detected warm reset clears the coarse stage.

Redfish ComputerSystem BootProgress is read by bmcweb from the host state
service (x86-power-control) only, so it does not show this value.
"""

import asyncio
import json
import logging
import os
import socket
import sys
import time

from dbus_fast import BusType, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property

LOG = logging.getLogger("ceb-gnrd-boot-progress")

BUS_NAME = "com.ctopai.CebGnrd.BootProgress"
HOST_PATH = "/xyz/openbmc_project/state/host0"
PROGRESS_IFACE = "xyz.openbmc_project.State.Boot.Progress"
STAGE_PREFIX = "xyz.openbmc_project.State.Boot.Progress.ProgressStages."
RAW_IFACE = "xyz.openbmc_project.State.Boot.Raw"
RAW_NAMESPACE = "/xyz/openbmc_project/state/boot"
PROPS = "org.freedesktop.DBus.Properties"
CHASSIS = ("xyz.openbmc_project.State.Chassis", "/xyz/openbmc_project/state/chassis0",
           "xyz.openbmc_project.State.Chassis", "CurrentPowerState")
OS_STATE = ("xyz.openbmc_project.State.OperatingSystem", "/xyz/openbmc_project/state/host0",
            "xyz.openbmc_project.State.OperatingSystem.Status", "OperatingSystemState")
POLL_SECONDS = 2
DETAIL_IFACE = "com.ctopai.CebGnrd.BootProgressDetail"

CATALOG_PATH = "/usr/share/ceb-gnrd/ami-aptio-v-post-codes.json"
with open(CATALOG_PATH, encoding="utf-8") as catalog_file:
    CATALOG = json.load(catalog_file)


def definition_for(code):
    if not isinstance(code, int) or not 0 <= code <= 0xFF:
        return None
    key = "%02X" % code
    if key in CATALOG["codes"]:
        return CATALOG["codes"][key]
    for entry in CATALOG["ranges"]:
        if int(entry["first"], 16) <= code <= int(entry["last"], 16):
            return entry
    return None


def checkpoint_for(code):
    return "Post%02X" % code if definition_for(code) else "Unknown"


def stage_for(code, after_handoff=False):
    entry = definition_for(code)
    if entry is None:
        return None
    # SEC/PEI values can also describe ACPI sleep transitions after boot.
    if after_handoff and "%02X" % code in CATALOG["acpi"]:
        return None
    return entry.get("stage")


class Checkpoint(ServiceInterface):
    def __init__(self):
        super().__init__(DETAIL_IFACE)
        self.detail = ""
        self.code = ""
        self.kind = ""

    @dbus_property(access=PropertyAccess.READ)
    def BootCheckpoint(self) -> "s":
        return self.detail

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCode(self) -> "s":
        return self.code

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCodeKind(self) -> "s":
        return self.kind

    def set(self, detail, code="", kind=""):
        if (detail, code, kind) == (self.detail, self.code, self.kind):
            return
        self.detail, self.code, self.kind = detail, code, kind
        self.emit_properties_changed({"BootCheckpoint": detail, "BootPostCode": code,
                                      "BootPostCodeKind": kind})


def sd_notify(message):
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


class Progress(ServiceInterface):
    def __init__(self):
        super().__init__(PROGRESS_IFACE)
        self.stage = "Unspecified"
        self.updated = 0

    @dbus_property(access=PropertyAccess.READ)
    def BootProgress(self) -> "s":
        return STAGE_PREFIX + self.stage

    @dbus_property(access=PropertyAccess.READ)
    def BootProgressLastUpdate(self) -> "t":
        return self.updated

    def set(self, stage, why):
        if stage == self.stage:
            return
        self.stage = stage
        self.updated = int(time.time() * 1_000_000)
        LOG.info("boot progress: %s (%s)", stage, why)
        self.emit_properties_changed({"BootProgress": STAGE_PREFIX + stage,
                                      "BootProgressLastUpdate": self.updated})


def post_code_of(value):
    """Raw POST value from Boot.Raw: (ay ay) or (t ay), without truncation."""
    if isinstance(value, Variant):
        value = value.value
    if isinstance(value, (list, tuple)) and value:
        first = value[0]
        if isinstance(first, (bytes, bytearray, list)):
            return int.from_bytes(first, "big") if len(first) else None
        if isinstance(first, int):
            return first
    if isinstance(value, int):
        return value
    return None


async def get_property(bus, service, path, iface, prop):
    reply = await bus.call(Message(destination=service, path=path, interface=PROPS,
                                   member="Get", signature="ss", body=[iface, prop]))
    if reply.message_type == MessageType.ERROR:
        raise RuntimeError(reply.error_name)
    return reply.body[0].value


async def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(levelname)s %(message)s")
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    progress = Progress()
    bus.export(HOST_PATH, progress)
    checkpoint = Checkpoint()
    bus.export(HOST_PATH, checkpoint)
    await bus.request_name(BUS_NAME)
    state = {"standby": False, "handoff": False}

    def on_message(msg):
        if (msg.message_type != MessageType.SIGNAL or msg.member != "PropertiesChanged"
                or not msg.body or msg.body[0] != RAW_IFACE):
            return
        changed = msg.body[1]
        if "Value" not in changed:
            return
        code = post_code_of(changed["Value"])
        if code is None:
            return
        entry = definition_for(code)
        checkpoint.set(checkpoint_for(code), "0x%02X" % code,
                       entry["kind"] if entry else "unknown")
        if code == 0xB3:
            state["handoff"] = False
            progress.set("Unspecified", "BIOS system reset checkpoint")
        stage = stage_for(code, state["handoff"])
        if stage:
            progress.set(stage, "POST code 0x%02X" % code)
            if stage == "OSStart":
                state["handoff"] = True

    bus.add_message_handler(on_message)
    match = ("type='signal',interface='%s',member='PropertiesChanged',"
             "path_namespace='%s',arg0='%s'" % (PROPS, RAW_NAMESPACE, RAW_IFACE))
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus", member="AddMatch",
                           signature="s", body=[match]))
    LOG.info("started, watching POST codes under %s", RAW_NAMESPACE)
    sd_notify("READY=1")

    last_watchdog = 0.0
    while True:
        try:
            power = str(await get_property(bus, *CHASSIS))
            if not power.endswith(".On"):
                state["handoff"] = False
                progress.set("Unspecified", "host off")
                checkpoint.set("")
                state["standby"] = False
            else:
                os_state = str(await get_property(bus, *OS_STATE))
                standby = os_state.endswith(".Standby")
                if standby and not checkpoint.detail:
                    checkpoint.set("POSTComplete")
                if standby and not state["standby"]:
                    state["handoff"] = True
                    if checkpoint.kind != "error":
                        progress.set("OSStart", "BIOS POST complete")
                if state.get("standby") and not standby:
                    state["handoff"] = False   # warm reset: the next POST starts over
                    checkpoint.set("")
                    progress.set("Unspecified", "BIOS POST complete deasserted")
                state["standby"] = standby
        except RuntimeError:
            pass
        now = time.monotonic()
        if now - last_watchdog >= 15:
            sd_notify("WATCHDOG=1")
            last_watchdog = now
        await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())
