#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""AST2600 bounded JTAG transport, guards and serial diagnostics.

Firmware updates are executed by cpld_svf.py from reviewed SVF commands.
The pure .bit parser/SPI vector helpers remain for development-host reference
audits; this module has no native bitstream programming entry point.
"""
import ctypes
import fcntl
import hashlib
import json
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
# DS600_1.8 section 2.9.11, EF3L90CG400: Golden feature/address at
# 0x060000, Golden bitstream at 0x061000. Never erase/program that region.
PRIMARY_FLASH_LIMIT = 0x060000
IDCODE = 0x00008C3B
REVERSE = bytes(int(f'{n:08b}'[::-1], 2) for n in range(256))


def console_debug_enabled():
    return os.environ.get('CEB_GNRD_CPLD_CONSOLE_DEBUG') == '1'


def console_log(message):
    """Best-effort serial copy; never block programming on a console reader."""
    if not console_debug_enabled():
        return
    fd = None
    try:
        fd = os.open('/dev/console', os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK | os.O_CLOEXEC)
        os.write(fd, (message[:1024].replace('\n', ' ') + '\n').encode('ascii', errors='replace'))
    except OSError:
        pass  # Missing/full console must not abort an update or extend its deadline.
    finally:
        if fd is not None:
            os.close(fd)


def trace(message):
    if not console_debug_enabled():
        return
    line = f'CPLD-TRACE [{time.monotonic():.6f}] pid={os.getpid()} {message}'
    # The worker's stderr is inherited from the service, independently of
    # its stdout JSON pipe. Emit before the operation, without parent polling.
    print(line, file=sys.stderr, flush=True)
    console_log(line)


def diagnostic_pause(label, deadline):
    """Give external serial capture time before a potentially disruptive step.

    flush=True only hands data to the kernel; it does not wait for UART TX.
    This bounded pause is a diagnostic observation window, not a guarantee
    that the console drained or a substitute for hardware signal capture.
    """
    if not console_debug_enabled():
        return
    if deadline - time.monotonic() <= 1:
        raise TimeoutError('Insufficient upgrade time for the pre-operation diagnostic pause')
    trace(f'DEBUG PAUSE 1s before {label}; operation has not started')
    time.sleep(1)
    if time.monotonic() >= deadline:
        raise TimeoutError('CPLD upgrade deadline expired during diagnostic pause')
    trace(f'DEBUG PAUSE END before {label}; beginning operation next')


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
    if len(data) > PRIMARY_FLASH_LIMIT:
        raise ValueError('Bitstream exceeds the 384 KiB primary region; Golden area must not be overwritten')
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
        if time.monotonic() >= self.deadline:
            raise TimeoutError('CPLD upgrade deadline expired during Host-state check')
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
        bits = self.scan_bits(count, value, instruction)
        prefix = 4 if instruction else 3
        # Keep state entry, data and UPDATE/IDLE in one bounded ioctl when
        # possible. Do not run busctl/guard between SHIFT and UPDATE. The TD
        # 2089-bit readback needs 2094 clocks, well below the 4096-clock ABI.
        returned = bytearray()
        for offset in range(0, len(bits), 4096):
            returned.extend(self.clocks(bits[offset:offset + 4096]))
        result = returned[prefix:prefix + count]
        return sum(((b >> 2) & 1) << i for i, b in enumerate(result))

    @staticmethod
    def scan_bits(count, value, instruction=False):
        if not 1 <= count <= 4096 or not 0 <= value < (1 << count):
            raise ValueError('Invalid JTAG scan size/value')
        bits = [((value >> i) & 1) * 2 for i in range(count)]
        bits[-1] |= 1  # EXIT1, sample last data bit, then UPDATE -> IDLE.
        return ([1, 1, 0, 0] if instruction else [1, 0, 0]) + bits + [1, 0]

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


if __name__ == '__main__':
    print('Use cpld_svf.py through the guarded CPLD update service.', file=sys.stderr)
    sys.exit(2)
