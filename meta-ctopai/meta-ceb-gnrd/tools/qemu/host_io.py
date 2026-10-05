#!/usr/bin/env python3
"""Host-side eSPI legacy I/O and USB enumeration against the QEMU models.

No guest firmware mocks: KCS, serial, HID and storage requests are handled by
the BMC's real drivers/services. Only the host side of the links is synthetic.
"""
import hashlib
import struct
import threading
import time

ESPI = "/machine/soc/espi"
VHUB = "/machine/soc/usb-vhub"


class USBStall(RuntimeError):
    """A real gadget STALL, distinct from a transport timeout/disconnect."""


class SCSIError(RuntimeError):
    def __init__(self, status, residue, data):
        super().__init__("SCSI command status=%d residue=%d" % (status, residue))
        self.status, self.residue, self.data = status, residue, data


class HostIO:
    def __init__(self, qmp):
        self.qmp = qmp
        self.lock = threading.RLock()

    def get(self, path, prop):
        return self.qmp.execute("qom-get", path=path, property=prop)

    def set(self, path, prop, value):
        return self.qmp.execute("qom-set", path=path, property=prop, value=value)

    def cycle(self, operation, port, value=None):
        command = "%s %x" % (operation, port)
        if value is not None:
            command += " %02x" % value
        with self.lock:
            self.set(ESPI, "host-cycle", command)
            result = self.get(ESPI, "host-result")
        if not result.startswith("ok:"):
            raise RuntimeError("eSPI %s: %s" % (command, result))
        return int(result[3:], 16) if result[3:] else None

    def read(self, port):
        return self.cycle("read", port)

    def write(self, port, value):
        self.cycle("write", port, value)

    def ipmi(self, request, timeout=10):
        """IPMI KCS write/read state machine, byte handshakes, not a fake reply."""
        deadline = time.monotonic() + timeout

        def status():
            if time.monotonic() >= deadline:
                raise TimeoutError("KCS handshake timed out")
            return self.read(0xca3)

        def wait(mask, expected):
            while True:
                s = status()
                if s & mask == expected:
                    return s
                time.sleep(0.005)

        def write(value, command=False):
            wait(2, 0)
            self.write(0xca3 if command else 0xca2, value)
            s = wait(2, 0)
            if s & 1:
                self.read(0xca2)  # write-phase dummy output
            return s

        if len(request) < 2:
            raise ValueError("KCS request requires netfn/lun and command")
        with self.lock:
            s = wait(2, 0)
            if s & 0xc0:
                raise RuntimeError("KCS is not idle; reset/abort the previous transfer first")
            if s & 1:
                self.read(0xca2)
            if write(0x61, True) & 0xc0 != 0x80:
                raise RuntimeError("KCS did not enter WRITE state")
            for byte in request[:-1]:
                if write(byte) & 0xc0 != 0x80:
                    raise RuntimeError("KCS left WRITE state")
            write(0x62, True)
            wait(2, 0)
            self.write(0xca2, request[-1])
            response = bytearray()
            while True:
                s = wait(2, 0)
                state = s & 0xc0
                if state == 0x80:
                    # The BMC userspace IPMI service has not replied yet.
                    time.sleep(0.005)
                    continue
                if state == 0:
                    if s & 1:
                        self.read(0xca2)  # final idle dummy
                    return bytes(response)
                if state != 0x40:
                    raise RuntimeError("KCS response state 0x%02x" % state)
                wait(1, 1)
                response.append(self.read(0xca2))
                if len(response) > 256:
                    raise RuntimeError("KCS response exceeds IPMI message limit")
                self.write(0xca2, 0x68)  # READ_BYTE


class USBHost:
    """A USB host that enumerates the real Linux vHub gadgets.

    HID interrupt reports are consumed and logged. Bulk-only SCSI requests read
    the actual backing media served by the BMC (including browser/jsnbd media).
    This is not an x86 CPU, OS, BIOS or USB host controller emulator.
    """
    def __init__(self, io, log):
        self.io = io
        self.log = log
        self.lock = threading.RLock()
        self.devices = {}
        self.connected = False
        self.tag = 0
        self.keyboard_text = ""
        self.pressed = {}
        self.reports = []
        self.media_result = None
        self.port_errors = {}
        self.retry_at = {}
        self.pointer = None
        self.state = {"available": True, "connected": False, "devices": []}

    def token(self, op, port, ep=0, data=b"", maximum=4096, timeout=2):
        payload = str(maximum) if op == "in" else data.hex() or "-"
        command = "%s %d %d %s" % (op, port, ep, payload)
        deadline = time.monotonic() + timeout
        while True:
            with self.io.lock:
                self.io.set(VHUB, "host-token", command)
                result = self.io.get(VHUB, "host-result")
            if result.startswith("ok:"):
                return bytes.fromhex(result[3:])
            if result == "stall":
                raise USBStall("USB STALL port%d ep%d (%s)" % (port, ep, op))
            if result != "nak":
                raise RuntimeError("USB %s port%d ep%d: %s" % (op, port, ep, result))
            if time.monotonic() >= deadline:
                raise TimeoutError("USB port%d ep%d NAK" % (port, ep))
            time.sleep(0.005)

    def control(self, port, kind, request, value=0, index=0, length=0, data=b""):
        with self.lock:
            self.token("setup", port, data=struct.pack("<BBHHH", kind, request,
                                                     value, index, length))
            result = bytearray()
            if kind & 0x80:
                while len(result) < length:
                    packet = self.token("in", port, maximum=64)
                    result.extend(packet)
                    if len(packet) < 64:
                        break
                self.token("out", port)  # status stage
            else:
                if len(data) != length:
                    raise ValueError("USB control OUT data length mismatch")
                for offset in range(0, length, 64):
                    self.token("out", port, data=data[offset:offset + 64])
                self.token("in", port, maximum=64)
            # Let the guest process the status ACK before the next SETUP.
            # QMP completion only means the token was accepted by the model.
            time.sleep(0.005)
            return bytes(result[:length])

    @staticmethod
    def parse_configuration(data):
        interfaces, current = [], None
        pos = 0
        while pos + 2 <= len(data):
            size, kind = data[pos:pos + 2]
            if size < 2 or pos + size > len(data):
                raise ValueError("truncated USB configuration descriptor")
            d = data[pos:pos + size]
            if kind == 4 and size >= 9:
                current = {"number": d[2], "class": d[5], "subclass": d[6],
                           "protocol": d[7], "endpoints": []}
                if d[3] == 0:
                    interfaces.append(current)
            elif kind == 5 and size >= 7 and current is not None:
                current["endpoints"].append({"address": d[2], "type": d[3] & 3,
                                            "packet": struct.unpack_from("<H", d, 4)[0]})
            elif kind == 0x21 and size >= 9 and current is not None:
                if d[6] == 0x22:
                    current["report_length"] = struct.unpack_from("<H", d, 7)[0]
            pos += size
        return interfaces

    def enumerate(self, port):
        descriptor = self.control(port, 0x80, 6, 0x100, length=18)
        if len(descriptor) != 18 or descriptor[1] != 1:
            raise RuntimeError("invalid USB device descriptor")
        self.control(port, 0, 5, port + 1)
        header = self.control(port, 0x80, 6, 0x200, length=9)
        if len(header) != 9 or header[1] != 2:
            raise RuntimeError("invalid USB configuration header")
        total = struct.unpack_from("<H", header, 2)[0]
        if not 9 <= total <= 4096:
            raise RuntimeError("USB configuration exceeds model limit")
        config = self.control(port, 0x80, 6, 0x200, length=total)
        if len(config) != total:
            raise RuntimeError("short USB configuration descriptor")
        self.control(port, 0, 9, header[5])
        device = {"port": port, "vid": "%04x" % struct.unpack_from("<H", descriptor, 8)[0],
                  "pid": "%04x" % struct.unpack_from("<H", descriptor, 10)[0],
                  "interfaces": self.parse_configuration(config), "reports": 0}
        for interface in device["interfaces"]:
            report_length = interface.get("report_length", 0)
            if interface["class"] == 3 and report_length:
                if report_length > 4096:
                    raise RuntimeError("HID report descriptor exceeds model limit")
                report = self.control(port, 0x81, 6, 0x2200,
                                      interface["number"], report_length)
                if len(report) != report_length:
                    raise RuntimeError("short HID report descriptor")
                interface["report_descriptor"] = report.hex()
        self.devices[port] = device
        self.log("USB port%d enumerated %s:%s" % (port, device["vid"], device["pid"]))
        for interface in device["interfaces"]:
            self.log("USB port%d interface%d class=%02x subclass=%02x protocol=%02x endpoints=%s" % (
                port, interface["number"], interface["class"], interface["subclass"],
                interface["protocol"], interface["endpoints"]))
        return device

    def set_connected(self, connected):
        with self.lock:
            self.io.set(VHUB, "host-connected", connected)
            self.connected = False
            self.devices.clear()
            self.media_result = None
            self.port_errors.clear()
            self.retry_at.clear()
            if connected:
                self.enumerate(0)  # root hub, then its downstream ports
            self.connected = connected
            self.pressed.clear()
            self.pointer = None
            self.state = {"available": True, "connected": connected, "devices": []}

    def hid_report(self, port, interface, endpoint, report):
        entry = {"port": port, "endpoint": endpoint, "hex": report.hex()}
        self.reports = (self.reports + [entry])[-40:]
        # Decode boot keyboard reports; other report formats remain visible raw.
        if interface["protocol"] == 1 and len(report) == 8:
            keys = set(report[2:]) - {0, 1, 2, 3}
            previous = self.pressed.get((port, endpoint), set())
            shift = bool(report[0] & 0x22)
            for key in report[2:]:
                if key not in keys - previous:
                    continue
                char = ""
                if 4 <= key <= 29:
                    char = chr(ord("a") + key - 4)
                    if shift:
                        char = char.upper()
                elif 30 <= key <= 39:
                    char = ("!@#$%^&*()" if shift else "1234567890")[key - 30]
                elif key == 40:
                    char = "\n"
                elif key == 42:
                    self.keyboard_text = self.keyboard_text[:-1]
                elif key == 43:
                    char = "\t"
                elif key == 44:
                    char = " "
                self.keyboard_text = (self.keyboard_text + char)[-8192:]
            self.pressed[(port, endpoint)] = keys
        # obmc-ikvm sends six-byte absolute pointer reports: buttons, LE16 X/Y,
        # signed wheel. Other descriptors remain raw rather than guessed.
        elif interface["protocol"] == 2 and len(report) == 6:
            self.pointer = {"port": port, "buttons": report[0],
                            "x": int.from_bytes(report[1:3], "little"),
                            "y": int.from_bytes(report[3:5], "little"),
                            "wheel": int.from_bytes(report[5:6], "little", signed=True)}
            entry["pointer"] = dict(self.pointer)
        self.log("USB HID port%d ep%d: %s%s" % (
            port, endpoint, report.hex(), " pointer=" + str(self.pointer) if "pointer" in entry else ""))

    def poll(self):
        if not self.connected:
            return
        with self.lock:
            for port in range(1, 8):
                if time.monotonic() < self.retry_at.get(port, 0):
                    continue
                try:
                    self.poll_port(port)
                    self.port_errors.pop(port, None)
                except (RuntimeError, OSError, ValueError, struct.error) as exc:
                    message = str(exc)
                    if self.port_errors.get(port) != message:
                        self.log("USB port%d failed: %s; retry in 1 s" % (port, message))
                    self.port_errors[port] = message
                    self.retry_at[port] = time.monotonic() + 1
            self.state = {"available": True, "connected": True,
                          "devices": [dict(d) for p, d in self.devices.items() if p],
                          "keyboard_text": self.keyboard_text, "reports": list(self.reports),
                          "pointer": self.pointer, "port_errors": dict(self.port_errors),
                          "media_result": self.media_result}

    def poll_port(self, port):
        status = self.control(0, 0xa3, 0, index=port, length=4)
        if len(status) != 4:
            raise RuntimeError("short USB hub port status")
        flags = int.from_bytes(status[:2], "little")
        changes = int.from_bytes(status[2:4], "little")
        if not flags & 1:
            if self.devices.pop(port, None):
                self.log("USB port%d disconnected" % port)
            self.pressed = {k: v for k, v in self.pressed.items() if k[0] != port}
            if self.pointer and self.pointer["port"] == port:
                self.pointer = None
            if self.media_result and self.media_result["port"] == port:
                self.media_result = None
            return
        if changes & 1 and port in self.devices:
            self.devices.pop(port)
        if port not in self.devices:
            self.control(0, 0x23, 3, 8, port)  # PORT_POWER
            self.control(0, 0x23, 3, 4, port)  # PORT_RESET
            self.log("USB port%d reset before enumeration" % port)
            time.sleep(0.05)
            self.enumerate(port)
        for bit in range(5):
            if changes & (1 << bit):
                self.control(0, 0x23, 1, 16 + bit, port)
        device = self.devices[port]
        for interface in device["interfaces"]:
            if interface["class"] != 3:
                continue
            for endpoint in interface["endpoints"]:
                if endpoint["type"] != 3 or not endpoint["address"] & 0x80:
                    continue
                try:
                    report = self.token("in", port, endpoint["address"] & 15,
                                        timeout=0)
                except TimeoutError:
                    continue
                device["reports"] += 1
                device["last_report"] = report.hex()
                self.hid_report(port, interface, endpoint["address"] & 15, report)

    def storage_endpoints(self, port):
        device = self.devices[port]
        iface = next(i for i in device["interfaces"] if i["class"] == 8
                     and i["subclass"] == 6 and i["protocol"] == 0x50)
        endpoints = [e for e in iface["endpoints"] if e["type"] == 2]
        rx = next(e for e in endpoints if e["address"] & 0x80)
        tx = next(e for e in endpoints if not e["address"] & 0x80)
        return iface, rx, tx

    def clear_halt(self, port, address):
        self.log("USB port%d CLEAR_FEATURE ENDPOINT_HALT ep%02x" % (port, address))
        self.control(port, 0x02, 1, index=address)

    def reset_bot(self, port):
        iface, rx, tx = self.storage_endpoints(port)
        self.log("USB port%d Bulk-Only Reset interface%d" % (port, iface["number"]))
        self.control(port, 0x21, 0xff, index=iface["number"])
        self.clear_halt(port, rx["address"])
        self.clear_halt(port, tx["address"])

    def scsi(self, port, cdb, length, lun=0):
        """USB Bulk-Only Transport, IN commands only (no media modification)."""
        with self.lock:
            iface, rx, tx = self.storage_endpoints(port)
            if not 1 <= len(cdb) <= 16 or not 0 <= length <= 1024 * 1024:
                raise ValueError("invalid CDB/transfer size")
            self.tag = (self.tag + 1) & 0xffffffff
            cbw = struct.pack("<IIIBBB", 0x43425355, self.tag, length, 0x80,
                              lun, len(cdb)) + cdb.ljust(16, b"\0")
            self.log("USB SCSI port%d lun%d tag%d CDB=%s expected=%d" % (
                port, lun, self.tag, cdb.hex(), length))
            self.token("out", port, tx["address"] & 15, cbw)
            result = bytearray()
            while len(result) < length:
                try:
                    packet = self.token("in", port, rx["address"] & 15, timeout=10)
                except USBStall:
                    # A failed IN command can halt the data pipe before CSW.
                    self.clear_halt(port, rx["address"])
                    break
                result.extend(packet)
                if len(result) > length:
                    raise RuntimeError("SCSI data exceeds requested transfer length")
                if len(packet) < rx["packet"]:
                    break
            try:
                csw = self.token("in", port, rx["address"] & 15, timeout=10)
            except USBStall:
                self.clear_halt(port, rx["address"])
                csw = self.token("in", port, rx["address"] & 15, timeout=10)
            if len(csw) != 13:
                raise RuntimeError("invalid mass-storage CSW")
            signature, tag, residue, status = struct.unpack("<IIIB", csw)
            self.log("USB SCSI CSW tag%d status=%d residue=%d received=%d" % (
                tag, status, residue, len(result)))
            if signature != 0x53425355 or tag != self.tag or status > 2 or residue > length:
                raise RuntimeError("invalid mass-storage CSW: " + csw.hex())
            if status:
                raise SCSIError(status, residue, bytes(result))
            if residue:
                raise RuntimeError("SCSI residue: %d bytes" % residue)
            if len(result) != length:
                raise RuntimeError("SCSI short read")
            return bytes(result)

    def scsi_ready(self, port, cdb, length):
        for attempt in range(3):
            try:
                return self.scsi(port, cdb, length)
            except SCSIError as exc:
                if exc.status == 2:
                    self.reset_bot(port)
                    raise RuntimeError("SCSI phase error; BOT reset performed") from None
                sense = self.scsi(port, bytes([3, 0, 0, 0, 18, 0]), 18)
                if len(sense) < 14 or sense[0] & 0x7f not in (0x70, 0x71):
                    raise RuntimeError("unsupported SCSI sense: " + sense.hex()) from None
                key, asc, ascq = sense[2] & 15, sense[12], sense[13]
                message = "SCSI sense key=%02x ASC=%02x ASCQ=%02x" % (key, asc, ascq)
                self.log("USB port%d %s" % (port, message))
                if attempt < 2 and (key == 6 or (key == 2 and asc == 4)):
                    time.sleep(0.2)
                    continue
                raise RuntimeError(message) from None

    def media_probe(self, port):
        if not 1 <= port <= 7:
            raise ValueError("请选择 USB 存储端口 1..7")
        with self.lock:
            try:
                inquiry = self.scsi_ready(port, bytes([0x12, 0, 0, 0, 36, 0]), 36)
                capacity = self.scsi_ready(port, bytes([0x25]) + bytes(9), 8)
                last, block = struct.unpack(">II", capacity)
                if not 1 <= block <= 65535:
                    raise RuntimeError("unsupported SCSI block size")
                if last == 0xffffffff:
                    raise RuntimeError("media requires READ CAPACITY(16); not supported by this probe")
                cdb = struct.pack(">BBIBHB", 0x28, 0, 0, 0, 1, 0)
                first = self.scsi_ready(port, cdb, block)
                result = {"port": port, "read_ok": True, "inquiry": inquiry.hex(),
                          "blocks": last + 1, "block_size": block,
                          "capacity_bytes": (last + 1) * block,
                          "lba0_sha256": hashlib.sha256(first).hexdigest()}
            except (RuntimeError, OSError, ValueError, KeyError, StopIteration, struct.error) as exc:
                message = str(exc) or "该 USB 端口没有 Bulk-Only SCSI 接口"
                self.log("USB 媒体检查失败 port%d：%s" % (port, message))
                if isinstance(exc, TimeoutError):
                    try:
                        self.reset_bot(port)
                    except (RuntimeError, OSError, ValueError, KeyError, StopIteration) as reset_error:
                        self.log("USB BOT 恢复失败：" + str(reset_error))
                self.media_result = {"port": port, "read_ok": False,
                                     "checked_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                     "error": message}
                self.state = dict(self.state, media_result=self.media_result)
                raise RuntimeError(self.media_result["error"]) from None
            self.media_result = result
            result["checked_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self.state = dict(self.state, media_result=result)
            return result
