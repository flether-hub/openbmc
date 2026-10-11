#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Restricted EF3L90 player, based on the reviewed TD 1.5 background SVF.

No arbitrary SVF execution. The input is a bounded Anlogic .bit; only the
reviewed erase/program/readback commands are emitted. Reference SVFs:
495be9e6fe834049bdf7be25a542071fcc165e4654d7d30c123186a717adc22f
cf303350980139dc36f03c8a63f7fca64217a54f36134a688ae615bd8b75ad89
"""
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

CONFIG = Path('/etc/ceb-gnrd/cpld-update.json')
DEVICE = '/dev/ceb-cpld-jtag'
RECEIPT = Path('/var/lib/ceb-gnrd-cpld-update/result.json')
MAX_IMAGE = 1024 * 1024
IDCODE = 0x00008C3B
REVERSE = bytes(int(f'{n:08b}'[::-1], 2) for n in range(256))


def bitstream(raw):
    if not 400 <= len(raw) <= MAX_IMAGE:
        raise ValueError('Invalid bitstream size (maximum 1 MiB)')
    boundary = raw.find(b'\n\n', 0, 8192)
    if boundary < 0:
        raise ValueError('Missing Anlogic bitstream header')
    header = raw[:boundary].decode('ascii', errors='strict')
    fields = dict(re.findall(r'^# ([^:\n]+):\s*(.+)$', header, re.M))
    if fields.get('Architecture') != 'ef3_9' or fields.get('Package') != 'EF3L90CG400B':
        raise ValueError('Only EF3L90CG400B bitstreams are accepted')
    feature = fields.get('Feature code', '')
    if not re.fullmatch(r'[0-9A-Fa-f]{36}', feature):
        raise ValueError('Invalid feature code')
    payload = bytearray()
    pos = boundary + 2
    while pos < len(raw):
        if pos + 2 > len(raw):
            raise ValueError('Truncated bitstream block')
        bits = int.from_bytes(raw[pos:pos + 2], 'big')
        pos += 2
        size = bits // 8
        if not size or bits % 8 or pos + size > len(raw):
            raise ValueError('Invalid bitstream block length')
        payload.extend(raw[pos:pos + size])
        pos += size
    # The supplied TD SPI vectors use the first 16 feature bytes. The final
    # two bytes of the 18-byte ASCII Feature code are not written to Flash.
    # Keep the complete field for explicit board approval.
    if not payload.startswith(b'\xff' * 32 + bytes.fromhex('cc55aa33')):
        raise ValueError('Unsupported bitstream preamble')
    data = bytes.fromhex(feature[:32]) + payload
    if len(data) > MAX_IMAGE:
        raise ValueError('Bitstream exceeds internal Flash capacity')
    data += b'\xff' * (-len(data) % 256)
    return data, feature.upper(), hashlib.sha256(raw).hexdigest()


def configuration():
    if CONFIG.stat().st_size > 8192:
        raise ValueError('Board programming configuration exceeds 8 KiB')
    value = json.loads(CONFIG.read_text())
    if not isinstance(value, dict):
        raise ValueError('Invalid board programming configuration')
    return value


def require_background(feature, cfg):
    # An SVF export option is not proof of the RUNNING design's persist_bit.
    reference = cfg.get('confirmation_reference')
    if (cfg.get('running_persist_bit_confirmed') is not True or
            not isinstance(reference, str) or not reference.strip()):
        raise ValueError('Running CPLD persist_bit=1 has not been confirmed')
    approved = cfg.get('approved_feature_codes')
    if not isinstance(approved, list) or not all(
            isinstance(item, str) and re.fullmatch(r'[0-9A-Fa-f]{36}', item)
            for item in approved):
        raise ValueError('Invalid approved feature code list')
    if feature not in [item.upper() for item in approved]:
        raise ValueError('Target feature code has not been approved for background programming')



def host_off():
    result = subprocess.run(
        ['busctl', 'get-property', 'xyz.openbmc_project.State.Chassis',
         '/xyz/openbmc_project/state/chassis0', 'xyz.openbmc_project.State.Chassis',
         'CurrentPowerState'], capture_output=True, text=True, timeout=2, check=True)
    return result.stdout.strip() == 's "xyz.openbmc_project.State.Chassis.PowerState.Off"'


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def checkpoint(value):
    encoded = json.dumps(value, separators=(',', ':')).encode()
    if len(encoded) > 8192:
        raise ValueError('Upgrade receipt exceeds its storage budget')
    RECEIPT.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = RECEIPT.with_suffix('.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(tmp, RECEIPT)
        directory = os.open(RECEIPT.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        tmp.unlink(missing_ok=True)


def event(phase, progress, detail, **extra):
    print(json.dumps(dict(phase=phase, progress=progress, detail=detail, **extra)), flush=True)


class Batch(ctypes.Structure):
    _fields_ = [('count', ctypes.c_uint32), ('half_period_ns', ctypes.c_uint32),
                ('bits', ctypes.c_uint8 * 4096)]


class Jtag:
    """Player holds the TAP in IDLE between scans (SVF ENDIR/ENDDR IDLE)."""
    def __init__(self, deadline, guard):
        self.fd = os.open(DEVICE, os.O_RDWR | os.O_CLOEXEC)
        self.deadline, self.guard = deadline, guard
        self.batch = Batch()
        self.batch.half_period_ns = 500  # <= 1 MHz, slower MMIO is safe.

    def close(self):
        os.close(self.fd)

    def clocks(self, bits):
        if len(bits) > 4096:
            raise ValueError('Oversize JTAG clock batch')
        if time.monotonic() >= self.deadline:
            raise TimeoutError('CPLD upgrade exceeded 10 minutes')
        self.guard()
        self.batch.count = len(bits)
        self.batch.bits[:len(bits)] = bits
        # Fixed-width ABI is identical on ARM32 and ARM64.
        request = (3 << 30) | (ctypes.sizeof(Batch) << 16) | (ord('J') << 8) | 0x40
        fcntl.ioctl(self.fd, request, self.batch, True)
        return bytes(self.batch.bits[:len(bits)])

    def reset_tap(self):
        self.clocks([1] * 8 + [0])

    def scan(self, count, value, instruction=False):
        # IDLE -> SELECT_DR -> [SELECT_IR] -> CAPTURE -> SHIFT.
        self.clocks([1, 1, 0, 0] if instruction else [1, 0, 0])
        bits = [((value >> i) & 1) * 2 for i in range(count)]
        bits[-1] |= 1  # EXIT1, sample last data bit, then UPDATE -> IDLE.
        result = self.clocks(bits)
        self.clocks([1, 0])
        return sum(((b >> 2) & 1) << i for i, b in enumerate(result))

    def ir(self, value):
        return self.scan(8, value, True)

    def run(self, count):
        while count:
            chunk = min(count, 4096)
            self.clocks([0] * chunk)
            count -= chunk

    def identify(self):
        self.reset_tap()
        self.ir(0xff)
        self.ir(0xff)
        self.ir(0x06)
        self.run(15)
        found = self.scan(32, 0)
        if found != IDCODE:
            raise ValueError(f'Unexpected JTAG IDCODE 0x{found:08x}')

    def spi(self, data, extra_bit=False):
        wire = bytes([0xa5]) + data
        return self.scan(len(wire) * 8 + int(extra_bit),
                         int.from_bytes(wire.translate(REVERSE), 'little'))

    def wren(self):
        self.scan(16, 0x60a5)


def update(path, job, remaining):
    if not 0 < remaining <= 600:
        raise ValueError("Invalid remaining upgrade timeout")
    deadline = time.monotonic() + remaining
    data, feature, digest = bitstream(Path(path).read_bytes())
    require_background(feature, configuration())
    old_boot = boot_id()
    last_host_check = 0.0

    def guard(force=False):
        nonlocal last_host_check
        now = time.monotonic()
        if force or now - last_host_check >= 0.5:
            if not host_off():
                raise RuntimeError('Host is no longer Off; programming stopped; do not reload CPLD')
            last_host_check = now

    guard(force=True)
    jtag = Jtag(deadline, guard)
    try:
        event('Preflight', 5, 'Checking JTAG IDCODE')
        jtag.identify()  # No feature changes, erase, or Refresh before this check.
        # Exact TD background entry; deliberately no IR 0x01 here.
        jtag.ir(0x80)
        jtag.scan(64, 0x00800000000000a5)
        jtag.run(200)
        jtag.ir(0xff)
        jtag.ir(0x39)
        jtag.run(50000)
        # Use the same reviewed SPI read command and one-bit delay as the
        # supplier's verify SVF. No inferred EF3 feature-register/JEDEC opcode.
        response = jtag.spi(bytes([0x03, 0, 0, 0]) + bytes(256), True)
        existing = ((response >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
        if existing[16:52] != b'\xff' * 32 + bytes.fromhex('cc55aa33'):
            raise RuntimeError('Internal Flash header not recognized; no erase attempted')
        event('Preflight', 8, 'Existing Flash header read successfully')
        jtag.wren()
        jtag.scan(32, 0x400080a5)
        jtag.run(100000)
        sectors = math.ceil(len(data) / 4096)
        for i in range(sectors):
            jtag.wren()
            jtag.spi(bytes([0x20]) + (i * 4096).to_bytes(3, 'big'))
            jtag.run(150000)
            event('Erasing', 10 + i * 20 // sectors, f'Erase sector {i + 1}/{sectors}')
        pages = len(data) // 256
        for i in range(pages):
            jtag.wren()
            jtag.spi(bytes([0x02]) + (i * 256).to_bytes(3, 'big') + data[i * 256:(i + 1) * 256])
            jtag.run(5000)
            if i % 16 == 0 or i + 1 == pages:
                event('Writing', 30 + i * 40 // pages, f'Write page {i + 1}/{pages}')
        for i in range(pages):
            value = jtag.spi(bytes([0x03]) + (i * 256).to_bytes(3, 'big') + bytes(256), True)
            found = ((value >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
            if found != data[i * 256:(i + 1) * 256]:
                raise RuntimeError(f'Flash readback mismatch at page {i}; Refresh blocked')
            if i % 16 == 0 or i + 1 == pages:
                event('Verifying', 70 + i * 23 // pages, f'Verify page {i + 1}/{pages}')
        jtag.ir(0xff)
        jtag.ir(0x20)
        jtag.scan(32, 0)  # Supplier MASK=0: not a DONE verification.
        jtag.ir(0x80)
        jtag.scan(64, 0x00000000000000a5)
        jtag.run(200)
        guard()
        # Exact independent TD Refresh sequence (IDCODE was checked above).
        jtag.ir(0x80)
        jtag.scan(64, 0x00800000000000a5)
        jtag.run(200)
        jtag.ir(0xff)
        jtag.ir(0xff)
        jtag.ir(0x06)
        jtag.run(15)
        if jtag.scan(32, 0) != IDCODE:
            raise RuntimeError('IDCODE changed before Refresh')
        jtag.ir(0xff)
        guard(force=True)
        # Durable, bounded receipt MUST precede the instruction resetting BMC.
        receipt = dict(job=job, phase='AwaitBmcReboot', progress=95,
                       detail='Flash verified; waiting for CPLD reload and BMC restart',
                       sha256=digest, feature=feature, bootId=old_boot,
                       armedUnix=time.time(),
                       deadlineUnix=time.time() + max(0, deadline - time.monotonic()),
                       flashVerified=True)
        checkpoint(receipt)
        event('AwaitBmcReboot', 95, receipt['detail'], flashVerified=True)
        # Host state is checked immediately before Refresh. After it is sent,
        # BMC services may disappear normally; do not turn that into Failed.
        jtag.guard = lambda: None
        jtag.ir(0x01)
        jtag.run(15)
        jtag.ir(0xff)
        jtag.run(200000)
        jtag.ir(0x80)
        jtag.scan(64, 0x00000000000000a5)
        jtag.run(200)
        # Returning from Refresh is not success: wait for a NEW BMC boot ID.
        while time.monotonic() < deadline:
            time.sleep(1)
        raise TimeoutError('Flash verified, but BMC did not restart within 10 minutes')
    finally:
        jtag.close()


if __name__ == '__main__':
    try:
        update(sys.argv[1], sys.argv[2], float(sys.argv[3]))
    except Exception as exc:
        event('Failed', 0, str(exc)[:512])
        sys.exit(1)
