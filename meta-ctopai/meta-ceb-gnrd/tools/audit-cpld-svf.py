#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline TD 1.5 EF3L90 profile audit. Never execute SVF or access JTAG.

Compare a .bit, background SPI/Verify/no-Refresh export and separate Refresh
export. This deliberately accepts only the explicit syntax of this reviewed
single-device profile, not the full SVF language (including sticky fields).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import types

MAX_SVF = 16 * 1024 * 1024


def load_player():
    path = (Path(__file__).resolve().parents[1] /
            'recipes-phosphor/flash/ceb-gnrd-cpld-update/files/cpld_jtag.py')
    spec = importlib.util.spec_from_file_location('audit_cpld_player', path)
    player = importlib.util.module_from_spec(spec)
    # Windows has no fcntl. Stub it on every platform: auditing needs only
    # the pure bit parser and vector constructors, never a real ioctl.
    stub = types.ModuleType('fcntl')
    def no_ioctl(*args, **kwargs):
        raise RuntimeError('Hardware access is forbidden in the offline audit')
    stub.ioctl = no_ioctl
    previous = sys.modules.get('fcntl')
    sys.modules['fcntl'] = stub
    try:
        spec.loader.exec_module(player)
    finally:
        if previous is None:
            del sys.modules['fcntl']
        else:
            sys.modules['fcntl'] = previous
    return player


def parse(text):
    """Return canonical commands; reject unsupported/incomplete commands."""
    text = re.sub(r'//[^\n]*|![^\n]*', '', text)
    if text.rsplit(';', 1)[-1].strip():
        raise ValueError('Unterminated SVF command')
    result = []
    for number, raw in enumerate(text.split(';'), 1):
        command = ' '.join(raw.upper().split())
        if not command:
            continue
        scan = re.fullmatch(r'(SIR|SDR) (\d+) (.+)', command)
        run = re.fullmatch(r'RUNTEST (\d+) TCK', command)
        frequency = re.fullmatch(r'FREQUENCY ([\d.E+-]+) HZ', command)
        if scan:
            kind, count, fields_text = scan.groups()
            count = int(count)
            if not 1 <= count <= 4096:
                raise ValueError(f'Command {number}: scan length out of range')
            field_pattern = r'(TDI|TDO|MASK|SMASK)\s*\(\s*([0-9A-F\s]+)\s*\)'
            if re.sub(field_pattern, '', fields_text).strip():
                raise ValueError(f'Command {number}: unsupported scan fields')
            fields = {}
            for name, value in re.findall(field_pattern, fields_text):
                if name in fields:
                    raise ValueError(f'Command {number}: duplicate {name}')
                fields[name] = int(''.join(value.split()), 16)
                if fields[name].bit_length() > count:
                    raise ValueError(f'Command {number}: {name} exceeds scan length')
            full = (1 << count) - 1
            if 'TDI' not in fields or ('TDO' in fields) != ('MASK' in fields):
                raise ValueError(f'Command {number}: explicit TDI/TDO/MASK required')
            if fields.get('SMASK', full) != full:
                raise ValueError(f'Command {number}: partial/sticky SMASK unsupported')
            mask = fields.get('MASK')
            tdo = None if mask is None else fields['TDO'] & mask
            item = (kind, count, fields['TDI'], tdo, mask)
        elif run:
            count = int(run[1])
            if not 1 <= count <= 1000000:
                raise ValueError(f'Command {number}: RUNTEST count out of range')
            item = ('RUNTEST', count)
        elif frequency:
            value = float(frequency[1])
            if value != 1000000:
                raise ValueError(f'Command {number}: only reviewed 1 MHz accepted')
            item = ('FREQUENCY', 1000000)
        elif command in ('TRST OFF', 'ENDIR IDLE', 'ENDDR IDLE',
                         'STATE RESET', 'STATE IDLE', 'HIR 0', 'HDR 0',
                         'TIR 0', 'TDR 0'):
            item = tuple(command.split())
        else:
            raise ValueError(f'Command {number}: unsupported command {command[:80]}')
        # Two consecutive waits in IDLE are equivalent to their sum. TD
        # emits two RUNTEST 50000 commands for the QE register write.
        if item[0] == 'RUNTEST' and result and result[-1][0] == 'RUNTEST':
            result[-1] = ('RUNTEST', result[-1][1] + item[1])
        else:
            result.append(item)
    return result


def scan(kind, count, tdi, tdo=None, mask=None):
    return (kind, count, tdi, None if mask is None else tdo & mask, mask)


def preamble():
    return [('TRST', 'OFF'), ('ENDIR', 'IDLE'), ('ENDDR', 'IDLE'),
            ('STATE', 'RESET'), ('STATE', 'IDLE'), ('FREQUENCY', 1000000),
            ('TDR', '0'), ('TIR', '0'), ('HDR', '0'), ('HIR', '0')]


def preparation(player):
    return [scan('SIR', 8, 0x80), scan('SDR', 64, 0x00800000000000a5),
            ('RUNTEST', 200), scan('SIR', 8, 0xff), scan('SIR', 8, 0xff),
            scan('SIR', 8, 6), ('RUNTEST', 15),
            scan('SDR', 32, 0, player.IDCODE, 0xffffffff)]


def expected_background(player, data):
    commands = preamble() + preparation(player)
    commands += [scan('SIR', 8, 0xff), scan('SIR', 8, 0x39), ('RUNTEST', 50000),
                 scan('SDR', 16, 0x60a5), scan('SDR', 32, 0x400080a5),
                 ('RUNTEST', 100000)]
    # Construct actual worker SPI TDI vectors through its pure scan recorder.
    wire = player.Jtag.__new__(player.Jtag)
    wire.scan = lambda count, value: scan('SDR', count, value)
    for address in range(0, len(data), 4096):
        commands += [scan('SDR', 16, 0x60a5),
                     wire.spi(b'\x20' + address.to_bytes(3, 'big')),
                     ('RUNTEST', 150000)]
    for address in range(0, len(data), 256):
        commands += [scan('SDR', 16, 0x60a5),
                     wire.spi(b'\x02' + address.to_bytes(3, 'big') + data[address:address + 256]),
                     ('RUNTEST', 5000)]
    mask = ((1 << 2048) - 1) << 41
    for address in range(0, len(data), 256):
        read = wire.spi(b'\x03' + address.to_bytes(3, 'big') + bytes(256), True)
        tdo = int.from_bytes(data[address:address + 256].translate(player.REVERSE), 'little') << 41
        commands.append(scan('SDR', read[1], read[2], tdo, mask))
    commands += [scan('SIR', 8, 0xff), scan('SIR', 8, 0x20), scan('SDR', 32, 0, 0, 0),
                 scan('SIR', 8, 0x80), scan('SDR', 64, 0xa5), ('RUNTEST', 200)]
    return commands


def expected_refresh(player):
    return preamble() + preparation(player) + [
        scan('SIR', 8, 0xff), scan('SIR', 8, 1), ('RUNTEST', 15),
        scan('SIR', 8, 0xff), ('RUNTEST', 200000),
        scan('SIR', 8, 0x80), scan('SDR', 64, 0xa5), ('RUNTEST', 200)]


def compare(actual, expected, name):
    if len(actual) != len(expected):
        raise ValueError(f'{name}: command count {len(actual)} != {len(expected)}')
    for number, (found, wanted) in enumerate(zip(actual, expected), 1):
        if found != wanted:
            # No megabytes of bitstream dump on a mismatch.
            raise ValueError(f'{name}: command {number} {found[0]} differs from reviewed profile')


def read_svf(path):
    with path.open('rb') as source:
        raw = source.read(MAX_SVF + 1)
    if len(raw) > MAX_SVF:
        raise ValueError(f'{path.name}: SVF exceeds 16 MiB audit limit')
    return parse(raw.decode('ascii')), hashlib.sha256(raw).hexdigest()


def audit(bit, program, refresh):
    player = load_player()
    with bit.open('rb') as source:
        raw = source.read(player.MAX_IMAGE + 1)
    data, feature, digest = player.bitstream(raw)
    background, background_hash = read_svf(program)
    reload, reload_hash = read_svf(refresh)
    compare(background, expected_background(player, data), 'Background SVF')
    compare(reload, expected_refresh(player), 'Refresh SVF')
    return dict(result='PASS', scope='Offline TD profile comparison; no hardware access',
                bitSha256=digest, backgroundSvfSha256=background_hash,
                refreshSvfSha256=reload_hash, idcode=f'0x{player.IDCODE:08x}', feature=feature,
                pages=len(data) // 256, sectors=(len(data) + 4095) // 4096,
                primaryBytes=len(data), goldenStart=player.PRIMARY_FLASH_LIMIT,
                largestScanBits=max(cmd[1] for cmd in background if cmd[0] in ('SIR', 'SDR')),
                endir='IDLE', enddr='IDLE', refresh='01 -> 15 TCK -> FF -> 200000 TCK',
                note='Runtime polling/Refresh modes deliberately differ from complete vendor SVF; '
                     'this audit does not prove IO hold or power recovery')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bit', type=Path, required=True)
    parser.add_argument('--program-svf', type=Path, required=True)
    parser.add_argument('--refresh-svf', type=Path, required=True)
    args = parser.parse_args()
    try:
        report = audit(args.bit, args.program_svf, args.refresh_svf)
    except (OSError, ValueError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
