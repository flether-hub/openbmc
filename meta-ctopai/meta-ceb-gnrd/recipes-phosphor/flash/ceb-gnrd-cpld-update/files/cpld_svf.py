#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Play the reviewed TD 1.5 EF3L90 background/verify/Refresh SVF profile.

Validate the entire file before opening JTAG. Execute its actual SIR, SDR and
RUNTEST commands on the dedicated AST2600 transport; no GPIO selection and no
bitstream-to-programming conversion. Unknown commands/profiles fail closed.
"""
import hashlib
from pathlib import Path
import re
import sys
import time

from cpld_jtag import (IDCODE, PRIMARY_FLASH_LIMIT, REVERSE, Jtag, boot_id,
                       checkpoint, configuration, diagnostic_pause, event,
                       host_off, require_background, trace)

MAX_SVF = 4 * 1024 * 1024
# Short mode transfers 32 bytes per block; a bounded Primary image can require
# almost 50000 commands. Keep both this count and the 4 MiB byte limit.
MAX_COMMANDS = 50000
WRITE_LENGTHS = {2088: 256, 296: 32}


class Command:
    __slots__ = ('kind', 'args', 'line')

    def __init__(self, kind, args, line):
        self.kind, self.args, self.line = kind, args, line

    @property
    def key(self):
        return (self.kind, *self.args)


def parse(raw):
    if not 100 <= len(raw) <= MAX_SVF:
        raise ValueError('SVF size must be 100 bytes to 4 MiB')
    text = raw.decode('ascii', errors='strict')
    # Keep newlines so diagnostics refer to the original file, not comments.
    text = re.sub(r'//[^\n]*|![^\n]*', '', text)
    if text.rsplit(';', 1)[-1].strip():
        raise ValueError('Unterminated SVF command')
    commands, line = [], 1
    for raw_command in text.split(';'):
        command_line = line + raw_command[:len(raw_command) - len(raw_command.lstrip())].count('\n')
        line += raw_command.count('\n')
        command = ' '.join(raw_command.upper().split())
        if not command:
            continue
        scan = re.fullmatch(r'(SIR|SDR) (\d+) (.+)', command)
        run = re.fullmatch(r'RUNTEST (\d+) TCK', command)
        frequency = re.fullmatch(r'FREQUENCY ([\d.E+-]+) HZ', command)
        if scan:
            kind, count, fields_text = scan.groups()
            count = int(count)
            if not 1 <= count <= 4096:
                raise ValueError(f'SVF line {command_line}: scan size exceeds transport limit')
            pattern = r'(TDI|TDO|MASK|SMASK)\s*\(\s*([0-9A-F\s]+)\s*\)'
            if re.sub(pattern, '', fields_text).strip():
                raise ValueError(f'SVF line {command_line}: unsupported scan fields')
            fields = {}
            for name, value in re.findall(pattern, fields_text):
                if name in fields:
                    raise ValueError(f'SVF line {command_line}: duplicate {name}')
                fields[name] = int(''.join(value.split()), 16)
                if fields[name].bit_length() > count:
                    raise ValueError(f'SVF line {command_line}: {name} exceeds scan length')
            if 'TDI' not in fields or ('TDO' in fields) != ('MASK' in fields):
                raise ValueError(f'SVF line {command_line}: explicit TDI/TDO/MASK required')
            if fields.get('SMASK', (1 << count) - 1) != (1 << count) - 1:
                raise ValueError(f'SVF line {command_line}: sticky/partial SMASK unsupported')
            mask = fields.get('MASK')
            args = (count, fields['TDI'], None if mask is None else fields['TDO'] & mask, mask)
        elif run:
            kind, args = 'RUNTEST', (int(run[1]),)
            if not 1 <= args[0] <= 1000000:
                raise ValueError(f'SVF line {command_line}: invalid RUNTEST count')
        elif frequency:
            if float(frequency[1]) != 1000000:
                raise ValueError('Only the reviewed 1 MHz SVF profile is supported')
            kind, args = 'FREQUENCY', (1000000,)
        elif command in ('TRST OFF', 'ENDIR IDLE', 'ENDDR IDLE', 'STATE RESET',
                         'STATE IDLE', 'TDR 0', 'TIR 0', 'HDR 0', 'HIR 0'):
            kind, value = command.split()
            args = (value,)
        else:
            raise ValueError(f'SVF line {command_line}: unsupported command {command[:80]}')
        commands.append(Command(kind, args, command_line))
        if len(commands) > MAX_COMMANDS:
            raise ValueError(f'SVF exceeds {MAX_COMMANDS} commands')
    return commands


def scan(kind, count, tdi, tdo=None, mask=None):
    return (kind, count, tdi, None if mask is None else tdo & mask, mask)


def spi_vector(data, extra=False):
    wire = (b'\xa5' + data).translate(REVERSE)
    return scan('SDR', len(wire) * 8 + int(extra), int.from_bytes(wire, 'little'))


def approved_feature(data, cfg):
    approved = cfg.get('approved_feature_codes')
    if not isinstance(approved, list):
        raise ValueError('Invalid approved feature code list')
    # The supplied SVF writes only 16 feature bytes. The final two bytes of
    # the .bit ASCII feature field are not present in this export.
    prefix = data[:16].hex().upper()
    matches = [item.upper() for item in approved if isinstance(item, str) and
               re.fullmatch(r'[0-9A-Fa-f]{36}', item) and item[:32].upper() == prefix]
    if len(set(matches)) != 1:
        raise ValueError('SVF 16-byte Flash feature does not uniquely match the approved design')
    require_background(matches[0], cfg)
    return matches[0]


def validate(raw, cfg):
    commands = parse(raw)
    writes = [c for c in commands if c.kind == 'SDR' and c.args[0] in WRITE_LENGTHS]
    lengths = {c.args[0] for c in writes}
    if len(lengths) != 1:
        raise ValueError('SVF must use one reviewed normal or short write length; mixed lengths are unsupported')
    chunk_bytes = WRITE_LENGTHS[lengths.pop()]
    length_mode = 'normal' if chunk_bytes == 256 else 'short'
    if not 1 <= len(writes) <= PRIMARY_FLASH_LIMIT // chunk_bytes:
        raise ValueError('SVF must program a bounded Primary image below the Golden region')
    data = bytearray()
    for page, command in enumerate(writes):
        count, value, tdo, mask = command.args
        wire = value.to_bytes(count // 8, 'little').translate(REVERSE)
        if (wire[:2] != b'\xa5\x02' or int.from_bytes(wire[2:5], 'big') != page * chunk_bytes or
                mask is not None or tdo is not None):
            raise ValueError(f'SVF line {command.line}: invalid or non-contiguous page write')
        data.extend(wire[5:])
    if data[16:52] != b'\xff' * 32 + bytes.fromhex('cc55aa33'):
        raise ValueError('SVF Flash payload has an unsupported Anlogic preamble')
    feature = approved_feature(data, cfg)
    expected = [('TRST', 'OFF'), ('ENDIR', 'IDLE'), ('ENDDR', 'IDLE'),
                ('STATE', 'RESET'), ('STATE', 'IDLE'), ('FREQUENCY', 1000000),
                ('TDR', '0'), ('TIR', '0'), ('HDR', '0'), ('HIR', '0'),
                scan('SIR', 8, 0x80), scan('SDR', 64, 0x00800000000000a5), ('RUNTEST', 200),
                scan('SIR', 8, 0xff), scan('SIR', 8, 0xff), scan('SIR', 8, 6), ('RUNTEST', 15),
                scan('SDR', 32, 0, IDCODE, 0xffffffff), scan('SIR', 8, 0xff),
                scan('SIR', 8, 0x39), ('RUNTEST', 50000), scan('SDR', 16, 0x60a5),
                scan('SDR', 32, 0x400080a5), ('RUNTEST', 50000), ('RUNTEST', 50000)]
    erase_start = len(expected)
    for address in range(0, len(data), 4096):
        expected += [scan('SDR', 16, 0x60a5), spi_vector(b'\x20' + address.to_bytes(3, 'big')),
                     ('RUNTEST', 150000)]
    write_start = len(expected)
    write_wait = 5000 if length_mode == 'normal' else 10000
    for address in range(0, len(data), chunk_bytes):
        expected += [scan('SDR', 16, 0x60a5),
                     spi_vector(b'\x02' + address.to_bytes(3, 'big') + data[address:address + chunk_bytes]),
                     ('RUNTEST', write_wait)]
    verify_start = len(expected)
    mask = ((1 << (chunk_bytes * 8)) - 1) << 41
    for address in range(0, len(data), chunk_bytes):
        read = spi_vector(b'\x03' + address.to_bytes(3, 'big') + bytes(chunk_bytes), True)
        tdo = int.from_bytes(data[address:address + chunk_bytes].translate(REVERSE), 'little') << 41
        expected.append(scan('SDR', read[1], read[2], tdo, mask))
    refresh_start = len(expected)
    # Exact combined normal (14:37) / short (15:18) exports, 2026-10-12.
    # This is a validation allowlist, not an alternate programming generator:
    # playback below always takes TDI/TDO/MASK/counts from the uploaded file.
    expected += [scan('SIR', 8, 0xff), scan('SIR', 8, 1), ('RUNTEST', 20)]
    for _ in range(4):
        expected += [scan('SIR', 8, 0xff), ('RUNTEST', 20)]
    expected += [scan('SIR', 8, 0xff), ('RUNTEST', 10000), scan('SIR', 8, 0x20),
                 scan('SDR', 32, 0, 0, 0), scan('SIR', 8, 0x80), scan('SDR', 64, 0xa5),
                 ('RUNTEST', 200)]
    if len(commands) != len(expected):
        raise ValueError('SVF command count differs from the reviewed combined background/verify/Refresh profile')
    for command, wanted in zip(commands, expected):
        if command.key != wanted:
            raise ValueError(f'SVF line {command.line}: {command.kind} differs from the approved profile')
    return dict(commands=commands, feature=feature, sha256=hashlib.sha256(raw).hexdigest(),
                flashSha256=hashlib.sha256(data).hexdigest(), pages=len(writes),
                sectors=(len(data) + 4095) // 4096, chunkBytes=chunk_bytes,
                lengthMode=length_mode, dataBytes=len(data), eraseStart=erase_start,
                writeStart=write_start, verifyStart=verify_start, refreshStart=refresh_start)


def label(index, command, plan):
    detail = f'SVF #{index + 1} line={command.line} {command.kind}'
    if command.kind in ('SIR', 'SDR'):
        count, value, _, mask = command.args
        detail += f' bits={count}'
        if count <= 64:
            detail += f' TDI=0x{value:X}'
        chunk_bytes = plan['chunkBytes']
        unit = 'page' if chunk_bytes == 256 else 'block'
        if count == 40 + chunk_bytes * 8:
            page = (index - plan['writeStart']) // 3
            detail += f' write {unit}={page + 1}/{plan["pages"]} bytes={chunk_bytes} address=0x{page * chunk_bytes:06x}'
        elif count == 41 + chunk_bytes * 8:
            page = index - plan['verifyStart']
            detail += f' verify {unit}={page + 1}/{plan["pages"]} bytes={chunk_bytes} address=0x{page * chunk_bytes:06x}'
        if mask is not None:
            detail += ' compare=TDO&MASK' if mask else ' MASK=0 (no comparison; not a DONE check)'
    elif command.kind == 'RUNTEST':
        detail += f' {command.args[0]} TCK in IDLE'
    else:
        detail += ' ' + str(command.args[0])
    return detail


def execute(jtag, index, command, plan):
    detail = label(index, command, plan)
    trace('BEGIN ' + detail)
    if command.kind in ('SIR', 'SDR'):
        count, value, expected, mask = command.args
        found = jtag.scan(count, value, command.kind == 'SIR')
        if mask is not None:
            difference = (found ^ expected) & mask
            if difference:
                bit = (difference & -difference).bit_length() - 1
                raise RuntimeError(f'{detail}: TDO mismatch at bit {bit}; Refresh blocked')
            trace('END ' + detail + (' MATCH' if mask else ' returned (unverified status)'))
            return
    elif command.kind == 'RUNTEST':
        jtag.run(command.args[0])
    elif command.kind == 'STATE':
        jtag.clocks([1] * 8 if command.args[0] == 'RESET' else [0])
    # ENDIR/ENDDR IDLE and zero headers/trailers are enforced by validation.
    # TRST OFF maps to the controller's already-deasserted nTRST; frequency
    # is bounded by its existing 500 ns minimum half-period. No GPIO is used.
    trace('END ' + detail)


def play_refresh(jtag, plan, before_send=None):
    """Compile the actual SVF tail to bounded clock batches, preserving order.

    Avoid logger/D-Bus gaps between FF, 01 and subsequent clocks. This cannot
    preserve TCK when BMC loses supply/reset. No nonzero TDO mask is allowed in
    this reviewed tail; masked status reads are explicitly not DONE checks.
    """
    bits, ends = [], []
    for index in range(plan['refreshStart'], len(plan['commands'])):
        command = plan['commands'][index]
        trace('QUEUED (not yet sent) ' + label(index, command, plan))
        if command.kind in ('SIR', 'SDR'):
            count, value, _, mask = command.args
            if mask:
                raise ValueError('Unexpected post-Refresh TDO comparison')
            bits.extend(Jtag.scan_bits(count, value, command.kind == 'SIR'))
        elif command.kind == 'RUNTEST':
            bits.extend([0] * command.args[0])
        else:
            raise ValueError('Unexpected post-Refresh command')
        ends.append((len(bits), index, command))
    trace(f'SVF Refresh tail clocks={len(bits)}; first batch contains SIR 01; outputs are not latched')
    completed = 0
    for offset in range(0, len(bits), 4096):
        chunk = bits[offset:offset + 4096]
        trace(f'BEGIN SVF Refresh clock batch={offset // 4096 + 1} clocks={offset}..{offset + len(chunk) - 1}')
        if offset == 0:
            diagnostic_pause('SVF Refresh first clock batch (no commands sent yet)', jtag.deadline)
            if before_send is not None:
                before_send()
        jtag.clocks(chunk)
        trace(f'END SVF Refresh clock batch={offset // 4096 + 1} returned')
        while completed < len(ends) and ends[completed][0] <= offset + len(chunk):
            _, index, command = ends[completed]
            trace('END ' + label(index, command, plan) + ' clocks returned (not a DONE check)')
            completed += 1


def update(path, job, remaining, expected_digest=None):
    if not 0 < remaining <= 600:
        raise ValueError('Invalid remaining upgrade timeout')
    deadline = time.monotonic() + remaining
    with Path(path).open('rb') as source:
        raw = source.read(MAX_SVF + 1)
    plan = validate(raw, configuration())
    if expected_digest is not None and plan['sha256'] != expected_digest:
        raise ValueError('Uploaded SVF changed after Start; programming blocked')
    trace(f'BEGIN SVF job={job} sha256={plan["sha256"]} lengthMode={plan["lengthMode"]} blockBytes={plan["chunkBytes"]} blocks={plan["pages"]} commands={len(plan["commands"])}')
    old_boot, last_host_check = boot_id(), 0.0

    def guard(force=False):
        nonlocal last_host_check
        now = time.monotonic()
        if now >= deadline:
            raise TimeoutError('CPLD SVF playback exceeded the 10-minute deadline')
        if force or now - last_host_check >= 0.5:
            if not host_off():
                raise RuntimeError('Host is no longer Off; SVF stopped; Refresh blocked')
            last_host_check = now
        if time.monotonic() >= deadline:
            raise TimeoutError('CPLD deadline expired during Host-state check')

    guard(force=True)
    jtag = Jtag(deadline, guard)
    try:
        trace('BEGIN independent preflight IDCODE check before any SVF register writes')
        jtag.identify()
        trace('END independent preflight IDCODE check MATCH')
        event('Preflight', 5, 'Playing SVF device check and background entry', programmingFormat='svf',
              lengthMode=plan['lengthMode'], programmingChunkBytes=plan['chunkBytes'])
        unit = 'page' if plan['chunkBytes'] == 256 else 'block'
        progress_stride = 4096 // plan['chunkBytes']
        for index, command in enumerate(plan['commands'][:plan['refreshStart']]):
            execute(jtag, index, command, plan)
            if plan['eraseStart'] <= index < plan['writeStart'] and command.kind == 'RUNTEST':
                sector = (index - plan['eraseStart']) // 3 + 1
                event('Erasing', 10 + sector * 20 // plan['sectors'], f'SVF erase sector {sector}/{plan["sectors"]}')
            elif plan['writeStart'] <= index < plan['verifyStart'] and command.kind == 'RUNTEST':
                page = (index - plan['writeStart']) // 3 + 1
                if page == 1 or page % progress_stride == 0 or page == plan['pages']:
                    event('Writing', 30 + page * 40 // plan['pages'], f'SVF write {unit} {page}/{plan["pages"]} ({plan["chunkBytes"]} bytes)')
            elif plan['verifyStart'] <= index:
                page = index - plan['verifyStart'] + 1
                if page == 1 or page % progress_stride == 0 or page == plan['pages']:
                    event('Verifying', 70 + page * 23 // plan['pages'], f'SVF verify {unit} {page}/{plan["pages"]} ({plan["chunkBytes"]} bytes)')
        trace(f'ALL FLASH BLOCKS VERIFIED blocks={plan["pages"]} blockBytes={plan["chunkBytes"]}; SVF Refresh not yet sent')
        event('Verifying', 93, f'SVF TDO/MASK readback passed for all {plan["pages"]} {unit}s', flashVerified=True)
        trace('BEGIN Final Host Off check and verified receipt before SVF Refresh')
        diagnostic_pause('SVF Refresh (operation has not started)', deadline)
        guard(force=True)
        receipt = dict(job=job, phase='AwaitBmcReboot', progress=95,
                       detail='SVF Flash verified; preparing original SVF Refresh and waiting for BMC restart',
                       sha256=plan['sha256'], flashSha256=plan['flashSha256'], feature=plan['feature'],
                       bootId=old_boot, armedUnix=time.time(),
                       deadlineUnix=time.time() + max(0, deadline - time.monotonic()),
                       flashVerified=True, verifiedPages=plan['pages'],
                       lengthMode=plan['lengthMode'], programmingChunkBytes=plan['chunkBytes'],
                       programmedBytes=plan['dataBytes'],
                       refreshSequenceCompleted=False, programmingFormat='svf')
        checkpoint(receipt)
        trace('END Persist SVF flashVerified receipt; Refresh not yet sent')
        event('AwaitBmcReboot', 95, receipt['detail'], flashVerified=True, refreshSequenceCompleted=False)
        # Receipt/logging can take time: check Off immediately before the
        # first post-verify FF, then allow normal D-Bus loss after activation.
        def begin_refresh():
            guard(force=True)
            jtag.guard = lambda: None
        play_refresh(jtag, plan, begin_refresh)
        receipt.update(progress=97, refreshSequenceCompleted=True,
                       detail='Complete SVF Refresh tail returned; waiting for a new BMC boot (not a DONE check)')
        checkpoint(receipt)
        event('AwaitBmcReboot', 97, receipt['detail'], refreshSequenceCompleted=True)
        while time.monotonic() < deadline:
            time.sleep(1)
        raise TimeoutError('SVF Flash verified, but BMC did not restart within 10 minutes')
    finally:
        trace('BEGIN close SVF JTAG device')
        jtag.close()
        trace('END close SVF JTAG device')


if __name__ == '__main__':
    try:
        update(sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
    except Exception as error:
        trace(f'FAILED SVF {type(error).__name__}: {str(error)[:512]}')
        event('Failed', 0, str(error)[:512])
        sys.exit(1)
