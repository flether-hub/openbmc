#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline TAP transport checks; fake clocks only."""
import unittest
from test_cpld_bit_update import player


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


if __name__ == '__main__': unittest.main()
