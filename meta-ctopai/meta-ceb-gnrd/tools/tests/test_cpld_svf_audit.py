#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline synthetic TAP/profile tests. No board, device node or vendor image."""
import importlib.util
from pathlib import Path
import unittest

TOOL = Path(__file__).resolve().parents[1] / 'audit-cpld-svf.py'
spec = importlib.util.spec_from_file_location('svf_audit', TOOL)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
player = audit.load_player()


class Tap:
    edges = {
        'IDLE': ('IDLE', 'SELECT_DR'), 'SELECT_DR': ('CAPTURE_DR', 'SELECT_IR'),
        'SELECT_IR': ('CAPTURE_IR', 'RESET'), 'CAPTURE_DR': ('SHIFT_DR', 'EXIT1_DR'),
        'CAPTURE_IR': ('SHIFT_IR', 'EXIT1_IR'), 'SHIFT_DR': ('SHIFT_DR', 'EXIT1_DR'),
        'SHIFT_IR': ('SHIFT_IR', 'EXIT1_IR'), 'EXIT1_DR': ('PAUSE_DR', 'UPDATE_DR'),
        'EXIT1_IR': ('PAUSE_IR', 'UPDATE_IR'), 'UPDATE_DR': ('IDLE', 'SELECT_DR'),
        'UPDATE_IR': ('IDLE', 'SELECT_DR'),
    }

    def __init__(self, tdo):
        self.state = 'IDLE'
        self.tdo = tdo
        self.position = 0
        self.tdi = 0
        self.blocks = []

    def clocks(self, bits):
        assert 0 < len(bits) <= 4096
        self.blocks.append(list(bits))
        output = []
        for bit in bits:
            assert bit in range(4)
            sampled = 1  # Non-data capture must not contaminate the result.
            if self.state in ('SHIFT_IR', 'SHIFT_DR'):
                sampled = (self.tdo >> self.position) & 1
                self.tdi |= ((bit >> 1) & 1) << self.position
                self.position += 1
            output.append(bit | (sampled << 2))
            self.state = self.edges[self.state][bit & 1]
        return bytes(output)


def encode(commands):
    lines = []
    for command in commands:
        if command[0] in ('SIR', 'SDR'):
            kind, count, tdi, tdo, mask = command
            line = f'{kind} {count} TDI ({tdi:x})'
            if mask is not None:
                line += f' TDO ({tdo:x}) MASK ({mask:x})'
        elif command[0] == 'FREQUENCY':
            line = 'FREQUENCY 1E6 HZ'
        elif command[0] == 'RUNTEST':
            line = f'RUNTEST {command[1]} TCK'
        else:
            line = ' '.join(command)
        lines.append(line + ';')
    return '\n'.join(lines)


class ScanTests(unittest.TestCase):
    def test_scan_tdi_tdo_and_idle_across_boundaries(self):
        for instruction in (False, True):
            for count in (1, 8, 25, 32, 64, 2088, 2089, 4090, 4091, 4092, 4096):
                with self.subTest(instruction=instruction, count=count):
                    tdi = ((1 << count) - 1) // 3
                    tdo = sum(1 << i for i in range(0, count, 7)) | (1 << (count - 1))
                    tap = Tap(tdo)
                    jtag = player.Jtag.__new__(player.Jtag)
                    jtag.clocks = tap.clocks
                    self.assertEqual(jtag.scan(count, tdi, instruction), tdo)
                    self.assertEqual(tap.tdi, tdi)
                    self.assertEqual(tap.position, count)
                    self.assertEqual(tap.state, 'IDLE')
                    self.assertEqual(sum(map(len, tap.blocks)), count + (6 if instruction else 5))
                    self.assertEqual(len(tap.blocks), 1 if count + (6 if instruction else 5) <= 4096 else 2)

    def test_runtest_generates_exact_idle_clocks(self):
        for count in (0, 15, 200, 4096, 50000, 150000, 200000):
            blocks = []
            jtag = player.Jtag.__new__(player.Jtag)
            jtag.clocks = lambda bits: blocks.append(bits)
            jtag.run(count)
            self.assertEqual(sum(map(len, blocks)), count)
            self.assertTrue(all(0 < len(b) <= 4096 and not any(b) for b in blocks))

    def test_invalid_scans_do_not_clock(self):
        jtag = player.Jtag.__new__(player.Jtag)
        jtag.clocks = lambda bits: self.fail('Invalid scan issued clocks')
        for count, value in ((0, 0), (4097, 0), (8, -1), (8, 256)):
            with self.assertRaises(ValueError):
                jtag.scan(count, value)


class AuditTests(unittest.TestCase):
    def test_synthetic_profile_roundtrip_and_split_wait(self):
        expected = audit.expected_background(player, bytes(range(256)))
        text = encode(expected).replace('RUNTEST 100000 TCK;',
                                        'RUNTEST 50000 TCK; // QE\nRUNTEST 50000 TCK;')
        actual = audit.parse(text.lower())
        audit.compare(actual, expected, 'synthetic')
        reload = audit.expected_refresh(player)
        audit.compare(audit.parse(encode(reload)), reload, 'refresh')

    def test_unsupported_or_ambiguous_syntax_rejected(self):
        for command in ('ENDDR DRPAUSE;', 'HIR 1 TDI (1);', 'TRST ON;',
                        'SIR 8 TDI (1) SMASK (7f);', 'SDR 8 TDI (0) TDO (0);',
                        'SDR 8 TDI (0) MASK (ff);', 'SIR 8 TDI (100);',
                        'SIR 8 TDI (1) TDI (1);', 'SIR 8 TDI (1) UNKNOWN (1);',
                        'SIR 8;', 'RUNTEST 15 SEC;', 'RUNTEST 0 TCK;',
                        'FREQUENCY 2E6 HZ;', 'SIR 8 TDI (1)', 'STATE RESET IDLE;'):
            with self.subTest(command=command), self.assertRaises(ValueError):
                audit.parse(command)

    def test_changed_vectors_waits_or_extra_refresh_rejected(self):
        expected = audit.expected_background(player, bytes(range(256)))
        for position in (1, 18, 22, 25, len(expected) - 7, len(expected) - 1):
            actual = list(expected)
            cmd = list(actual[position])
            if cmd[0] in ('SIR', 'SDR'):
                cmd[2] ^= 1
            elif cmd[0] == 'RUNTEST':
                cmd[1] += 1
            else:
                cmd[-1] = 'RESET'
            actual[position] = tuple(cmd)
            with self.subTest(position=position), self.assertRaises(ValueError):
                audit.compare(actual, expected, 'modified')
        with self.assertRaises(ValueError):
            audit.compare(expected + [audit.scan('SIR', 8, 1)], expected, 'extra Refresh')
        # Compare all TDO data and the mask, ignoring only bits outside MASK.
        index = next(i for i, c in enumerate(expected) if c[:2] == ('SDR', 2089))
        for field in (3, 4):
            actual = list(expected)
            cmd = list(actual[index])
            cmd[field] ^= 1 << 41
            actual[index] = tuple(cmd)
            with self.assertRaises(ValueError):
                audit.compare(actual, expected, 'modified readback')

    def test_masked_bits_and_full_smask(self):
        self.assertEqual(audit.parse('SDR 8 TDI (0) TDO (ff) MASK (0) SMASK (ff);'),
                         [audit.scan('SDR', 8, 0, 0, 0)])

    def test_hardware_ioctl_disabled(self):
        with self.assertRaisesRegex(RuntimeError, 'forbidden'):
            player.fcntl.ioctl(0, 0)


if __name__ == '__main__':
    unittest.main()
