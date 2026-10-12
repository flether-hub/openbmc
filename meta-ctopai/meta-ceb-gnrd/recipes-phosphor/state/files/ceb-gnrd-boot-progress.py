#!/usr/bin/env python3
"""CEB-GNRD host boot progress from BIOS POST codes.

Nothing in OpenBMC turns POST codes into xyz.openbmc_project.State.Boot.Progress
(phosphor-host-postd only publishes the raw code, phosphor-post-code-manager only
records the history), and this host does not report its boot progress itself.
This service watches the POST codes from phosphor-host-postd
(xyz.openbmc_project.State.Boot.Raw, port 0x80) and publishes BootProgress /
BootProgressLastUpdate on /xyz/openbmc_project/state/host0, where the IPMI
Boot_Progress sensor and the web discrete sensor table read it.

Checkpoint meanings use the same reference catalog as the POST-code page.
Each boot sequence tracks 4F/60 (DXE entry), 90 (BDS), AD (Ready To Boot)
and AF/AE (boot handoff). Early AA/AF do not establish a boot handoff.
Before DXE, reused B0-BF have Intel RC reference meanings. Other platform
bytes remain unmatched, including D*/E* and 50/55; they are not diagnosed
as AMI errors without a matching phase context. A reference interpretation
does not establish the GNR-D-specific meaning or the module writing a code.
Unknown/OEM codes retain their raw value and do not change BootProgress.
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


class PostContext:
    """Track phase anchors; source labels remain reference interpretations."""
    def __init__(self):
        self.reset()

    def reset(self):
        self.phase = "unknown"
        self.ready = False
        self.handoff = False

    def consume(self, code):
        if not isinstance(code, int) or not 0 <= code <= 0xFF:
            return "unresolved"
        key = "%02X" % code
        entry = definition_for(code)
        rules = CATALOG["sequenceRules"]
        if self.handoff and key in CATALOG["acpi"]:
            return "acpi"
        if key == "01" or (key == "10" and self.phase == "unknown"):
            self.reset()
            self.phase = "pei"
        if not self.handoff and key in rules["dxeEntry"]:
            if self.phase != "bds":
                self.phase = "dxe"
            return "ami"
        if key == rules["bdsEntry"] and self.phase in ("dxe", "bds"):
            self.phase = "bds"
            return "ami"
        if self.phase == "pei":
            if "B0" <= key <= "BF":
                return "intelMemory"
            if entry and entry["kind"] == "progress" and any(
                    first <= key <= last for first, last in rules["earlyAmiProgress"]):
                return "ami"
            return "intelPlatform"
        if self.phase == "unknown":
            return "unresolved"
        if self.phase == "bds" and key == rules["readyToBoot"]:
            self.ready = True
        if self.phase == "bds" and self.ready and key in rules["bootExit"]:
            self.handoff = True
        if self.phase == "bds" and key == "B3":
            self.reset()
            return "amiReset"
        if not entry or entry["kind"] in ("reserved", "oem") or entry["phase"] not in ("DXE", "BDS"):
            return "platformUnknown"
        if entry["phase"] == "BDS" and self.phase != "bds":
            return "platformUnknown"
        return "ami"


def checkpoint_for(code):
    return "Post%02X" % code if definition_for(code) else "Unknown"


def stage_for(code, after_handoff=False, context=""):
    entry = definition_for(code)
    if entry is None or context not in ("ami", "amiReset"):
        return None
    # Virtual address mapping is a late handoff checkpoint only after
    # the anchored AD -> AF/AE sequence (or external POST-complete state).
    if code in (0xB0, 0xB1) and not after_handoff:
        return None
    return entry.get("stage")


class Checkpoint(ServiceInterface):
    def __init__(self):
        super().__init__(DETAIL_IFACE)
        self.detail = ""
        self.code = ""
        self.kind = ""
        self.context = ""

    @dbus_property(access=PropertyAccess.READ)
    def BootCheckpoint(self) -> "s":
        return self.detail

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCode(self) -> "s":
        return self.code

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCodeKind(self) -> "s":
        return self.kind

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCodeContext(self) -> "s":
        return self.context

    def set(self, detail, code="", kind="", context=""):
        if (detail, code, kind, context) == (self.detail, self.code, self.kind, self.context):
            return
        self.detail, self.code, self.kind, self.context = detail, code, kind, context
        self.emit_properties_changed({"BootCheckpoint": detail, "BootPostCode": code,
                                      "BootPostCodeKind": kind, "BootPostCodeContext": context})


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
    state = {"standby": False}
    post_context = PostContext()

    def on_message(msg):
        if (msg.message_type != MessageType.SIGNAL or msg.member != "PropertiesChanged"
                or not msg.body):
            return
        if msg.path == HOST_PATH and msg.body[0] == "xyz.openbmc_project.State.Host":
            host_state = msg.body[1].get("CurrentHostState")
            if host_state and str(host_state.value).endswith(".Off"):
                post_context.reset()
                progress.set("Unspecified", "host Off/reset event")
                checkpoint.set("")
                state["standby"] = False
            return
        if msg.body[0] != RAW_IFACE:
            return
        changed = msg.body[1]
        if "Value" not in changed:
            return
        code = post_code_of(changed["Value"])
        if code is None:
            return
        entry = definition_for(code)
        context = post_context.consume(code)
        kind = entry["kind"] if entry else "unknown"
        if context == "intelMemory":
            kind = "reference"
        elif context in ("intelPlatform", "platformUnknown", "unresolved"):
            kind = "unknown"
        elif context == "acpi":
            kind = "runtime"
        checkpoint.set(checkpoint_for(code), "0x%02X" % code,
                       kind, context)
        if context == "amiReset":
            progress.set("Unspecified", "BIOS system reset checkpoint")
        stage = stage_for(code, post_context.handoff, context)
        if stage:
            progress.set(stage, "POST code 0x%02X" % code)

    bus.add_message_handler(on_message)
    match = ("type='signal',interface='%s',member='PropertiesChanged',"
             "path_namespace='%s',arg0='%s'" % (PROPS, RAW_NAMESPACE, RAW_IFACE))
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus", member="AddMatch",
                           signature="s", body=[match]))
    host_match = ("type='signal',interface='%s',member='PropertiesChanged',"
                  "path='%s',arg0='xyz.openbmc_project.State.Host'" % (PROPS, HOST_PATH))
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus", member="AddMatch",
                           signature="s", body=[host_match]))
    LOG.info("started, watching POST codes under %s", RAW_NAMESPACE)
    sd_notify("READY=1")

    last_watchdog = 0.0
    while True:
        try:
            power = str(await get_property(bus, *CHASSIS))
            if not power.endswith(".On"):
                post_context.reset()
                progress.set("Unspecified", "host off")
                checkpoint.set("")
                state["standby"] = False
            else:
                os_state = str(await get_property(bus, *OS_STATE))
                standby = os_state.endswith(".Standby")
                if standby and not checkpoint.detail:
                    checkpoint.set("POSTComplete")
                if standby and not state["standby"]:
                    post_context.handoff = True
                    post_context.phase = "bds"
                    post_context.ready = True
                    if checkpoint.kind != "error":
                        progress.set("OSStart", "BIOS POST complete")
                if state.get("standby") and not standby:
                    # Warm reset: the next POST starts over.
                    post_context.reset()
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
