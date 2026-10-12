#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Restricted EF3L90 player, based on the reviewed TD 1.5 background SVF.

No arbitrary SVF execution. The input is a bounded Anlogic .bit. Erase/program
and full readback retain the supplied vectors; optional openfpgaloader mode
uses SPI status polling/reset under the board owner's EF3/EF2 compatibility
assumption. Reference SVFs:
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


def refresh_mode(cfg):
    mode = cfg.get('refresh_mode', 'vendor')
    if mode not in ('vendor', 'direct', 'openfpgaloader'):
        raise ValueError('refresh_mode must be vendor, direct or openfpgaloader')
    return mode



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


    def flash_status(self):
        # Retain the EF3 A5 SPI tunnel already verified against TD vectors.
        # Assuming EF2/EF3 compatibility, SPI 05 reads WIP bit0 and WEL bit1.
        # Prefix A5 + opcode 05 occupy 16 bits, followed by the 1-bit delay.
        value = self.spi(bytes([0x05, 0x00]), True)
        status = REVERSE[(value >> 17) & 0xff]
        if status == 0xff:
            raise RuntimeError('Flash status is 0xFF; status polling unsupported or device unavailable; programming blocked')
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
        raise TimeoutError(f'{operation} timed out: Flash status={value}, mask=0x{mask:02x}, expected=0x{expected:02x}; Refresh blocked')

    def write_enable_checked(self):
        self.wren()
        # Require idle AND WEL, not merely WEL on a busy device.
        return self.wait_flash_status(0x03, 0x02, 1, 'Flash write-enable')

    def wait_flash_ready(self, timeout, operation):
        return self.wait_flash_status(0x01, 0x00, timeout, operation)

    def refresh_openfpgaloader(self):
        # Mirrors Anlogic::reset() at upstream bf2b52916e7b6216ba1cc0b30933827d7735b05d.
        # Enter/leave every IR scan in IDLE. Keep the short sequence in one
        # bounded ioctl so there are no user-space/logging/Host-check gaps
        # between IR 01, its 15 clocks and BYPASS. Power loss can still abort it.
        control = (self.scan_bits(8, 0xff, True) + self.scan_bits(8, 0x01, True) +
                   [0] * 15 + self.scan_bits(8, 0xff, True))
        idle_first = 4096 - len(control)
        trace('openFPGALoader critical batch: FF -> 01 -> 15 TCK -> FF, then initial idle clocks')
        self.clocks(control + [0] * idle_first)
        trace(f'openFPGALoader critical batch returned; {200000 - idle_first} idle clocks remain')
        self.run(200000 - idle_first)


def update(path, job, remaining, selected_mode=None):
    if not 0 < remaining <= 600:
        raise ValueError("Invalid remaining upgrade timeout")
    deadline = time.monotonic() + remaining
    trace(f'BEGIN job={job} timeoutRemaining={remaining:.3f}s')
    data, feature, digest = bitstream(Path(path).read_bytes())
    cfg = configuration()
    require_background(feature, cfg)
    mode = refresh_mode(cfg if selected_mode is None else {'refresh_mode': selected_mode})
    trace(f'Refresh mode={mode}; openfpgaloader assumes EF3/EF2 compatibility; direct is experimental')
    trace(f'Image approved sha256={digest} feature={feature} bytes={len(data)}; no output latch is provided')
    old_boot = boot_id()
    last_host_check = 0.0

    def guard(force=False):
        nonlocal last_host_check
        now = time.monotonic()
        if force or now - last_host_check >= 0.5:
            if not host_off():
                raise RuntimeError('Host is no longer Off; programming stopped; do not reload CPLD')
            last_host_check = now

    def step(label, operation, *args, **kwargs):
        trace(f'BEGIN {label}')
        if label in (
                'Post-verify read_status SDR 32 (not a DONE check)',
                'Final Host Off check before Refresh',
                'Persist flashVerified receipt before Refresh',
                'Refresh SIR 01',
                'openFPGALoader Refresh critical batch'):
            diagnostic_pause(label, deadline)
        result = operation(*args, **kwargs)
        trace(f'END {label}')
        return result

    step('Host Off check before programming', guard, force=True)
    jtag = step('Open JTAG Master-1', Jtag, deadline, guard)
    try:
        event('Preflight', 5, 'Checking JTAG IDCODE')
        step('Initial IDCODE check', jtag.identify)
        trace('BEGIN background programming entry (no Refresh)')
        # Exact TD background entry; deliberately no IR 0x01 here.
        jtag.ir(0x80)
        jtag.scan(64, 0x00800000000000a5)
        jtag.run(200)
        jtag.ir(0xff)
        jtag.ir(0x39)
        jtag.run(50000)
        trace('END background programming entry')
        # Use the same reviewed SPI read command and one-bit delay as the
        # supplier's verify SVF. No inferred EF3 feature-register/JEDEC opcode.
        response = jtag.spi(bytes([0x03, 0, 0, 0]) + bytes(256), True)
        existing = ((response >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
        if existing[16:52] != b'\xff' * 32 + bytes.fromhex('cc55aa33'):
            raise RuntimeError('Internal Flash header not recognized; no erase attempted')
        event('Preflight', 8, 'Existing Flash header read successfully')
        trace('Existing Flash header accepted; BEGIN QE setup')
        if mode == 'openfpgaloader':
            status = step('Initial SPI Flash WIP check (05)', jtag.wait_flash_ready, 2, 'Initial Flash readiness')
            trace(f'SPI Flash status=0x{status:02x}; status polling enabled')
            jtag.write_enable_checked()
        else:
            jtag.wren()
        jtag.scan(32, 0x400080a5)
        if mode == 'openfpgaloader':
            step('Wait for QE write completion', jtag.wait_flash_ready, 2, 'QE register write')
        else:
            jtag.run(100000)
        trace('END QE setup')
        sectors = math.ceil(len(data) / 4096)
        for i in range(sectors):
            trace(f'BEGIN erase sector {i + 1}/{sectors} address=0x{i * 4096:06x}')
            if mode == 'openfpgaloader':
                jtag.write_enable_checked()
            else:
                jtag.wren()
            jtag.spi(bytes([0x20]) + (i * 4096).to_bytes(3, 'big'))
            if mode == 'openfpgaloader':
                jtag.wait_flash_ready(10, f'Erase sector {i + 1}/{sectors}')
            else:
                jtag.run(150000)
            trace(f'END erase sector {i + 1}/{sectors}')
            event('Erasing', 10 + i * 20 // sectors, f'Erase sector {i + 1}/{sectors}')
        pages = len(data) // 256
        for i in range(pages):
            if i % 16 == 0 or i >= pages - 16:
                trace(f'BEGIN write page {i + 1}/{pages} address=0x{i * 256:06x}')
            if mode == 'openfpgaloader':
                jtag.write_enable_checked()
            else:
                jtag.wren()
            jtag.spi(bytes([0x02]) + (i * 256).to_bytes(3, 'big') + data[i * 256:(i + 1) * 256])
            if mode == 'openfpgaloader':
                jtag.wait_flash_ready(2, f'Program page {i + 1}/{pages}')
            else:
                jtag.run(5000)
            if (i + 1) % 16 == 0 or i >= pages - 16:
                trace(f'END write page {i + 1}/{pages}')
            if i % 16 == 0 or i + 1 == pages:
                event('Writing', 30 + i * 40 // pages, f'Write page {i + 1}/{pages}')
        for i in range(pages):
            if i % 16 == 0 or i >= pages - 16:
                trace(f'BEGIN verify page {i + 1}/{pages} address=0x{i * 256:06x}')
            value = jtag.spi(bytes([0x03]) + (i * 256).to_bytes(3, 'big') + bytes(256), True)
            found = ((value >> 41) & ((1 << 2048) - 1)).to_bytes(256, 'little').translate(REVERSE)
            if found != data[i * 256:(i + 1) * 256]:
                raise RuntimeError(f'Flash readback mismatch at page {i}; Refresh blocked')
            if (i + 1) % 16 == 0 or i >= pages - 16:
                trace(f'END verify page {i + 1}/{pages} MATCH')
            if i % 16 == 0 or i + 1 == pages:
                event('Verifying', 70 + i * 23 // pages, f'Verify page {i + 1}/{pages}')
        event('Verifying', 93, f'Flash readback passed for all {pages} pages',
              flashVerified=True)
        trace(f'ALL FLASH PAGES VERIFIED pages={pages}; Refresh not yet sent')
        if mode == 'vendor':
            step('Post-verify status SIR FF', jtag.ir, 0xff)
            step('Post-verify read_status SIR 20', jtag.ir, 0x20)
            step('Post-verify read_status SDR 32 (not a DONE check)', jtag.scan, 32, 0)
            step('Exit programming SIR 80', jtag.ir, 0x80)
            step('Exit programming SDR 64 00000000000000A5', jtag.scan, 64, 0x00000000000000a5)
            step('Exit programming RUNTEST 200 TCK', jtag.run, 200)
            step('Host Off check after verify', guard)
            # Exact independent TD Refresh sequence (IDCODE was checked above).
            step('Refresh preparation SIR 80', jtag.ir, 0x80)
            step('Refresh preparation SDR 64 00800000000000A5', jtag.scan, 64, 0x00800000000000a5)
            step('Refresh preparation RUNTEST 200 TCK', jtag.run, 200)
            step('Refresh preparation SIR FF (1)', jtag.ir, 0xff)
            step('Refresh preparation SIR FF (2)', jtag.ir, 0xff)
            step('Refresh preparation SIR 06 IDCODE', jtag.ir, 0x06)
            step('Refresh preparation RUNTEST 15 TCK', jtag.run, 15)
            found_id = step('Refresh preparation SDR 32 IDCODE', jtag.scan, 32, 0)
            trace(f'Refresh IDCODE=0x{found_id:08x} expected=0x{IDCODE:08x}')
            if found_id != IDCODE:
                raise RuntimeError('IDCODE changed before Refresh')
            step('Refresh preparation SIR FF', jtag.ir, 0xff)
        elif mode == 'direct':
            # Board-owner-authorized experiment: stay in IDLE after the last
            # verified SPI read and go directly to IR 01. No inferred register
            # writes or post-verify SDR 32. Initial exact IDCODE is still required.
            trace('EXPERIMENT direct Refresh: skipping post-verify status, mode-exit and repeated IDCODE sequence')
        else:
            trace('openFPGALoader mode: skip SIR 20/SDR 32 and EF3 control-register exit/re-entry')
        step('Final Host Off check before Refresh', guard, force=True)
        # Durable, bounded receipt MUST precede the instruction resetting BMC.
        receipt = dict(job=job, phase='AwaitBmcReboot', progress=95,
                       detail=f'Flash verified; preparing {mode} JTAG Refresh and waiting for BMC restart',
                       sha256=digest, feature=feature, bootId=old_boot,
                       armedUnix=time.time(),
                       deadlineUnix=time.time() + max(0, deadline - time.monotonic()),
                       flashVerified=True, refreshSequenceCompleted=False, refreshMode=mode)
        if mode == 'openfpgaloader':
            receipt['compatibilityAssumption'] = 'EF3/EF2 SPI status and Refresh compatible; no IO-hold protocol implemented'
        step('Persist flashVerified receipt before Refresh', checkpoint, receipt)
        event('AwaitBmcReboot', 95, receipt['detail'], flashVerified=True,
              refreshSequenceCompleted=False, refreshMode=mode)
        # Host state is checked immediately before Refresh. After it is sent,
        # BMC services may disappear normally; do not turn that into Failed.
        trace('NEXT SIR 01 triggers CPLD reload; BMC power/reset and serial may disappear; outputs are not latched')
        def begin_refresh(operation, *args):
            # The diagnostic pause/receipt write may take seconds. Check Off
            # again AFTER those waits, immediately before the disruptive scan.
            guard(force=True)
            jtag.guard = lambda: None
            return operation(*args)

        if mode == 'openfpgaloader':
            step('openFPGALoader Refresh critical batch', begin_refresh, jtag.refresh_openfpgaloader)
        else:
            step('Refresh SIR 01', begin_refresh, jtag.ir, 0x01)
            step('Refresh RUNTEST 15 TCK', jtag.run, 15)
        if mode == 'vendor':
            step('Refresh SIR FF', jtag.ir, 0xff)
            step('Refresh RUNTEST 200000 TCK', jtag.run, 200000)
            step('Refresh cleanup SIR 80', jtag.ir, 0x80)
            step('Refresh cleanup SDR 64 00000000000000A5', jtag.scan, 64, 0x00000000000000a5)
            step('Refresh cleanup RUNTEST 200 TCK', jtag.run, 200)
        elif mode == 'direct':
            trace('EXPERIMENT direct Refresh: IR 01 and 15 TCK returned; no further JTAG commands will be sent')
        # This records completion of the selected sequence, not FPGA DONE.
        # If BMC power/reset interrupts it, the durable flag remains false.
        receipt.update(progress=97, refreshSequenceCompleted=True,
                       detail=f'{mode} JTAG Refresh sequence completed; waiting for BMC restart')
        step('Persist Refresh sequence completion (not a DONE check)', checkpoint, receipt)
        event('AwaitBmcReboot', 97, receipt['detail'], refreshSequenceCompleted=True)
        trace('WAIT for BMC restart within original deadline; no BMC software reboot is issued')
        # Returning from Refresh is not success: wait for a NEW BMC boot ID.
        while time.monotonic() < deadline:
            time.sleep(1)
        raise TimeoutError('Flash verified, but BMC did not restart within 10 minutes')
    finally:
        trace('BEGIN close JTAG device')
        jtag.close()
        trace('END close JTAG device')


if __name__ == '__main__':
    try:
        update(sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
    except Exception as exc:
        trace(f'FAILED {type(exc).__name__}: {str(exc)[:512]}')
        event('Failed', 0, str(exc)[:512])
        sys.exit(1)
