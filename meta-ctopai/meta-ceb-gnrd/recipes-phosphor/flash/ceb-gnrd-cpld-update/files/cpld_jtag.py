#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""AST2600 bounded JTAG transport, guards and journal diagnostics.

Program an approved Anlogic .bit image and verify every Flash page.
Activation is a separate, operator-controlled full AC power cycle. No
Refresh, configuration reset or post-verification mode-exit command is sent.
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


def trace(message):
    line = f'CPLD-TRACE [{time.monotonic():.6f}] pid={os.getpid()} {message}'
    # The worker's stderr is inherited from the service, independently of
    # its stdout JSON pipe. Emit before the operation, without parent polling.
    print(line, file=sys.stderr, flush=True)


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
    # An export option is not proof of the RUNNING design's persist_bit.
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



def bit_plan(raw, cfg):
    data, feature, digest = bitstream(raw)
    require_background(feature, cfg)
    return dict(data=data, feature=feature, sha256=digest,
                flashSha256=hashlib.sha256(data).hexdigest(), pages=len(data) // 256,
                sectors=(len(data) + 4095) // 4096)


def host_off():
    result = subprocess.run(
        ['busctl', 'get-property', 'xyz.openbmc_project.State.Chassis',
         '/xyz/openbmc_project/state/chassis0', 'xyz.openbmc_project.State.Chassis',
         'CurrentPowerState'], capture_output=True, text=True, timeout=2, check=True)
    if result.stdout.strip() != 's "xyz.openbmc_project.State.Chassis.PowerState.Off"':
        return False
    stable = subprocess.run(
        ['busctl', 'get-property', 'xyz.openbmc_project.State.Chassis',
         '/xyz/openbmc_project/state/chassis0', 'xyz.openbmc_project.State.Chassis',
         'FirmwareProgrammingAllowed'], capture_output=True, text=True, timeout=2, check=True)
    return stable.stdout.strip() == 'b true'


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
    """Hold the TAP in IDLE between programming scans."""
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

    def flash_status(self):
        # Restore the earlier .bit path's A5 SPI 05 status polling.
        # EF3/EF2 status compatibility was used on this board previously.
        value = self.spi(bytes([0x05, 0]), True)
        status = REVERSE[(value >> 17) & 0xff]
        if status == 0xff:
            raise RuntimeError('Flash status is 0xFF; device/status polling unavailable')
        return status

    def wait_flash_status(self, mask, expected, timeout, operation):
        until = min(self.deadline, time.monotonic() + timeout)
        status = None
        while time.monotonic() < until:
            status = self.flash_status()
            if time.monotonic() >= until:
                break
            if status & mask == expected:
                return status
            time.sleep(min(0.002, max(0, until - time.monotonic())))
        value = 'unknown' if status is None else f'0x{status:02x}'
        raise TimeoutError(f'{operation} timed out: Flash status={value}')

    def write_enable_checked(self):
        self.wren()
        return self.wait_flash_status(0x03, 0x02, 1, 'Flash write-enable')

    def wait_flash_ready(self, timeout, operation):
        return self.wait_flash_status(0x01, 0, timeout, operation)


def update(path, job, remaining, expected_digest=None):
    if not 0 < remaining <= 600:
        raise ValueError('Invalid remaining upgrade timeout')
    deadline = time.monotonic() + remaining
    with Path(path).open('rb') as source:
        raw = source.read(MAX_IMAGE + 1)
    plan = bit_plan(raw, configuration())
    if expected_digest is not None and plan['sha256'] != expected_digest:
        raise ValueError('Uploaded .bit changed after Start; programming blocked')
    data, pages = plan['data'], plan['pages']
    trace(f'BEGIN BIT job={job} sha256={plan["sha256"]} pages={pages}; manual AC activation required')
    old_boot, last_host_check = boot_id(), 0.0

    def guard(force=False):
        nonlocal last_host_check
        now = time.monotonic()
        if now >= deadline:
            raise TimeoutError('CPLD programming exceeded the 10-minute deadline')
        if force or now - last_host_check >= 0.5:
            if not host_off():
                raise RuntimeError('Host is no longer Off; CPLD programming stopped')
            last_host_check = now
        if time.monotonic() >= deadline:
            raise TimeoutError('CPLD deadline expired during Host-state check')

    guard(force=True)
    jtag = Jtag(deadline, guard)
    try:
        event('Preflight', 5, 'Checking .bit image and JTAG IDCODE', programmingFormat='bit')
        jtag.identify()
        trace('BEGIN background programming entry')
        jtag.ir(0x80)
        jtag.scan(64, 0x00800000000000a5)
        jtag.run(200)
        jtag.ir(0xff)
        jtag.ir(0x39)
        jtag.run(50000)
        response = jtag.spi(bytes([0x03, 0, 0, 0]) + bytes(256), True)
        existing = ((response >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
        if existing[16:52] != b'\xff' * 32 + bytes.fromhex('cc55aa33'):
            raise RuntimeError('Existing Flash header not recognized; no erase attempted')
        jtag.wait_flash_ready(2, 'Initial Flash readiness')
        jtag.write_enable_checked()
        jtag.scan(32, 0x400080a5)
        jtag.wait_flash_ready(2, 'QE register write')
        trace('END background entry and QE setup')
        for sector in range(plan['sectors']):
            address = sector * 4096
            trace(f'BEGIN erase sector {sector + 1}/{plan["sectors"]} address=0x{address:06x}')
            jtag.write_enable_checked()
            jtag.spi(bytes([0x20]) + address.to_bytes(3, 'big'))
            jtag.wait_flash_ready(10, f'Erase sector {sector + 1}')
            trace(f'END erase sector {sector + 1}/{plan["sectors"]}')
            event('Erasing', 10 + (sector + 1) * 20 // plan['sectors'],
                  f'Erase sector {sector + 1}/{plan["sectors"]}')
        for page in range(pages):
            address = page * 256
            verbose = page % 16 == 0 or page >= pages - 16
            if verbose:
                trace(f'BEGIN write page {page + 1}/{pages} address=0x{address:06x}')
            jtag.write_enable_checked()
            jtag.spi(bytes([0x02]) + address.to_bytes(3, 'big') + data[address:address + 256])
            jtag.wait_flash_ready(2, f'Program page {page + 1}')
            if verbose:
                trace(f'END write page {page + 1}/{pages}')
            if page == 0 or (page + 1) % 16 == 0 or page + 1 == pages:
                event('Writing', 30 + (page + 1) * 40 // pages, f'Write page {page + 1}/{pages}')
        for page in range(pages):
            address = page * 256
            verbose = page % 16 == 0 or page >= pages - 16
            if verbose:
                trace(f'BEGIN verify page {page + 1}/{pages} address=0x{address:06x}')
            response = jtag.spi(bytes([0x03]) + address.to_bytes(3, 'big') + bytes(256), True)
            found = ((response >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
            if found != data[address:address + 256]:
                raise RuntimeError(f'Flash readback mismatch at page {page + 1}; programming failed')
            if verbose:
                trace(f'END verify page {page + 1}/{pages} MATCH')
            if page == 0 or (page + 1) % 16 == 0 or page + 1 == pages:
                event('Verifying', 70 + (page + 1) * 29 // pages, f'Verify page {page + 1}/{pages}')
        guard(force=True)
        trace(f'ALL FLASH PAGES VERIFIED pages={pages}; no Refresh/reset/mode-exit will be sent')
        event('Verifying', 99, f'All {pages} Flash pages verified; finalizing programming result', flashVerified=True)
    finally:
        trace('BEGIN close JTAG after programming; no activation command')
        jtag.close()
        trace('END close JTAG')
    receipt = dict(job=job, phase='Completed', progress=100,
                   detail='CPLD programming succeeded; all Flash pages verified. Disconnect all AC inputs, wait for standby power to turn off, then restore AC to load the new CPLD firmware.',
                   sha256=plan['sha256'], flashSha256=plan['flashSha256'], feature=plan['feature'],
                   bootId=old_boot, flashVerified=True, verifiedPages=pages,
                   programmingFormat='bit', programmedBytes=len(data),
                   activationRequired=True, activationMethod='ACPowerCycle', autoRefresh=False)
    checkpoint(receipt)
    event('Completed', 100, receipt['detail'], flashVerified=True, verifiedPages=pages,
          activationRequired=True, activationMethod='ACPowerCycle', autoRefresh=False,
          programmingFormat='bit', programmedBytes=len(data))


if __name__ == '__main__':
    try:
        update(sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
    except Exception as error:
        trace(f'FAILED BIT {type(error).__name__}: {str(error)[:512]}')
        event('Failed', 0, str(error)[:512])
        sys.exit(1)
