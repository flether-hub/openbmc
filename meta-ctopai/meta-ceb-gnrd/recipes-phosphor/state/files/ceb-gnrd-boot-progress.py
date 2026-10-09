#!/usr/bin/env python3
"""CEB-GNRD host boot progress from BIOS POST codes.

Nothing in OpenBMC turns POST codes into xyz.openbmc_project.State.Boot.Progress
(phosphor-host-postd only publishes the raw code, phosphor-post-code-manager only
records the history), and this host does not report its boot progress itself.
This service watches the POST codes from phosphor-host-postd
(xyz.openbmc_project.State.Boot.Raw, port 0x80) and publishes BootProgress /
BootProgressLastUpdate on /xyz/openbmc_project/state/host0, where the IPMI
Boot_Progress sensor and the web discrete sensor table read it.

The code ranges follow the public AMI Aptio checkpoint list plus Intel's
memory reference code (MRC) range; the BIOS vendor's POST code document for the
GNR-D BIOS is authoritative and STAGES below must be adjusted to it:

  0x01-0x0F  SEC                                      PrimaryProcInit
  0x10-0x2A  PEI, before memory                       PrimaryProcInit
  0x2B-0x30  PEI memory initialisation (AMI)          MemoryInit
  0xB0-0xDF  Intel MRC memory training (PEI only)     MemoryInit
  0x31-0x5F  PEI after memory (CPU, chipset)          SecondaryProcInit
  0x60-0x67  DXE core, CPU                            SecondaryProcInit
  0x68-0x6F  DXE PCI host bridge                      PCIInit
  0x70-0x91  DXE chipset, devices                     MotherboardInit
  0x92-0x99  PCI bus enumeration                      PCIInit
  0x9A-0xAC  USB, SATA, consoles, boot devices        MotherboardInit
  0xAD-0xAF  ready to boot / exit boot services       OSStart

Other codes (S3 resume 0xE0-0xEF, recovery and errors 0xF0-0xFF, DXE codes
outside the ranges) leave the stage unchanged.  BIOS POST complete
(BMC_BIOS_BOOT_OK, OperatingSystemState Standby from x86-power-control) also
means OSStart; host power off resets the stage to Unspecified.

A separate board interface preserves the latest raw POST code and generic AMI
checkpoint for Web display. POST-complete polling does not overwrite that
checkpoint. No POST checkpoint is treated as proof that the OS is running.

Redfish ComputerSystem BootProgress is read by bmcweb from the host state
service (x86-power-control) only, so it does not show this value.
"""

import asyncio
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

# Generic AMI checkpoints, not a vendor-specific GNR-D BIOS contract.
# Do not interpret reserved/OEM/error codes as ordinary boot milestones.
CHECKPOINTS = {
    0x01: "ResetDetection",
    0x02: "APBeforeMicrocode",
    0x03: "SystemAgentBeforeMicrocode",
    0x04: "PCHBeforeMicrocode",
    0x06: "MicrocodeLoad",
    0x07: "APAfterMicrocode",
    0x08: "SystemAgentAfterMicrocode",
    0x09: "PCHAfterMicrocode",
    0x0B: "CacheInit",
    0x10: "PEICore",
    0x31: "MemoryInstalled",
    0x4F: "DXEIPL",
    0x60: "DXECore",
    0x61: "NVRAMInit",
    0x62: "PCHRuntime",
    0x68: "PCIHostBridge",
    0x69: "SystemAgentDXE",
    0x6A: "SystemAgentSMM",
    0x70: "PCHDXE",
    0x71: "PCHSMM",
    0x72: "PCHDevices",
    0x78: "ACPIInit",
    0x79: "CSMInit",
    0x90: "BootDeviceSelection",
    0x91: "DriverConnection",
    0x92: "PCIBusInit",
    0x93: "PCIHotPlugInit",
    0x94: "PCIEnumeration",
    0x95: "PCIResourceRequest",
    0x96: "PCIResourceAssignment",
    0x97: "ConsoleOutput",
    0x98: "ConsoleInput",
    0x99: "SuperIOInit",
    0x9A: "USBInit",
    0x9B: "USBReset",
    0x9C: "USBDetection",
    0x9D: "USBEnable",
    0xA0: "IDEInit",
    0xA1: "IDEReset",
    0xA2: "IDEDetection",
    0xA3: "IDEEnable",
    0xA4: "SCSIInit",
    0xA5: "SCSIReset",
    0xA6: "SCSIDetection",
    0xA7: "SCSIEnable",
    0xA8: "SetupPassword",
    0xA9: "BIOSSetup",
    0xAB: "SetupInput",
    0xAD: "ReadyToBoot",
    0xAE: "LegacyBoot",
    0xAF: "ExitBootServices",
    0xB0: "VirtualAddressMapBegin",
    0xB1: "VirtualAddressMapEnd",
}
CHECKPOINT_RANGES = (
    (0x11, 0x14, "CPUBeforeMemory"),
    (0x15, 0x18, "SystemAgentBeforeMemory"),
    (0x19, 0x1C, "PCHBeforeMemory"),
    (0x2B, 0x2F, "MemoryInit"),
    (0x32, 0x36, "CPUAfterMemory"),
    (0x37, 0x3A, "SystemAgentAfterMemory"),
    (0x3B, 0x3E, "PCHAfterMemory"),
    (0x63, 0x67, "CPUDXE"),
    (0x6B, 0x6F, "SystemAgentDXE"),
    (0x73, 0x77, "PCHDXE"),
)


def checkpoint_for(code, in_pei):
    # This platform also uses Intel MRC codes overlapping AMI runtime codes.
    # Keep their raw value without claiming a specific training operation.
    if in_pei and 0xB0 <= code <= 0xDF:
        return "PlatformSpecific"
    if code in CHECKPOINTS:
        return CHECKPOINTS[code]
    for first, last, detail in CHECKPOINT_RANGES:
        if first <= code <= last:
            return detail
    return "Unknown"


class Checkpoint(ServiceInterface):
    def __init__(self):
        super().__init__(DETAIL_IFACE)
        self.detail = ""
        self.code = ""

    @dbus_property(access=PropertyAccess.READ)
    def BootCheckpoint(self) -> "s":
        return self.detail

    @dbus_property(access=PropertyAccess.READ)
    def BootPostCode(self) -> "s":
        return self.code

    def set(self, detail, code=""):
        if (detail, code) == (self.detail, self.code):
            return
        self.detail, self.code = detail, code
        self.emit_properties_changed({"BootCheckpoint": detail, "BootPostCode": code})


# (first code, last code, stage, PEI only)
STAGES = [
    (0x01, 0x0F, "PrimaryProcInit", False),
    (0x10, 0x2A, "PrimaryProcInit", False),
    (0x2B, 0x30, "MemoryInit", False),
    (0xB0, 0xDF, "MemoryInit", True),
    (0x31, 0x5F, "SecondaryProcInit", False),
    (0x60, 0x67, "SecondaryProcInit", False),
    (0x68, 0x6F, "PCIInit", False),
    (0x70, 0x91, "MotherboardInit", False),
    (0x92, 0x99, "PCIInit", False),
    (0x9A, 0xAC, "MotherboardInit", False),
    (0xAD, 0xAF, "OSStart", False),
]


def stage_for(code, in_pei):
    for first, last, stage, pei_only in STAGES:
        if first <= code <= last and (in_pei or not pei_only):
            return stage
    return None


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
    """First byte of the POST code from Boot.Raw Value: (ay ay) or (t ay)."""
    if isinstance(value, Variant):
        value = value.value
    if isinstance(value, (list, tuple)) and value:
        first = value[0]
        if isinstance(first, (bytes, bytearray, list)):
            return first[0] if len(first) else None
        if isinstance(first, int):
            return first & 0xFF
    if isinstance(value, int):
        return value & 0xFF
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
    state = {"pei": True}

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
        if code >= 0x60 and code < 0xB0:
            state["pei"] = False          # DXE reached: 0xB0-0xDF is no longer MRC
        checkpoint.set(checkpoint_for(code, state["pei"]), "0x%02X" % code)
        stage = stage_for(code, state["pei"])
        if stage:
            progress.set(stage, "POST code 0x%02X" % code)

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
                state["pei"] = True
                progress.set("Unspecified", "host off")
                checkpoint.set("")
                state["standby"] = False
            else:
                os_state = str(await get_property(bus, *OS_STATE))
                standby = os_state.endswith(".Standby")
                if standby and not checkpoint.detail:
                    checkpoint.set("POSTComplete")
                if standby and progress.stage != "OSStart":
                    progress.set("OSStart", "BIOS POST complete")
                if state.get("standby") and not standby:
                    state["pei"] = True   # warm reset: the next POST starts over
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
