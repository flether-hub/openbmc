#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline SVF playback tests. Fake transport only; no BMC/Flash/GPIO access.

Optionally set CEB_SVF_REVIEW_FILE to audit a real export in addition to the
synthetic fixtures. That file is only read, never played on hardware.
"""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / 'recipes-phosphor/flash/ceb-gnrd-cpld-update/files'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fcntl = types.ModuleType('fcntl')
fcntl.LOCK_EX, fcntl.LOCK_NB = 2, 4
fcntl.flock = lambda *args: None
fcntl.ioctl = lambda *args: (_ for _ in ()).throw(AssertionError('Hardware ioctl forbidden'))
sys.modules['fcntl'] = fcntl
transport = load('cpld_jtag', FILES / 'cpld_jtag.py')
svf = load('cpld_svf', FILES / 'cpld_svf.py')
audit = load('svf_audit_fixture', ROOT / 'tools/audit-cpld-svf.py')
FEATURE = 'FFDD66BB22FFFFFFA2FFFFFFFFFFFFFF9368'
CFG = dict(running_persist_bit_confirmed=True, confirmation_reference='offline fixture',
           approved_feature_codes=[FEATURE])


def encode(commands):
    lines = ['// Synthetic offline test fixture.']
    for kind, *args in commands:
        if kind in ('SIR', 'SDR'):
            count, tdi, tdo, mask = args
            line = f'{kind} {count} TDI ({tdi:x})'
            if mask is not None:
                line += f' TDO ({tdo:x}) MASK ({mask:x})'
        elif kind == 'RUNTEST':
            line = f'RUNTEST {args[0]} TCK'
        elif kind == 'FREQUENCY':
            line = f'FREQUENCY {args[0]} HZ'
        else:
            line = f'{kind} {args[0]}'
        lines.append(line + ';')
    return ('\n'.join(lines) + '\n').encode()


def fixture(data=None):
    if data is None:
        data = bytes.fromhex(FEATURE[:32]) + b'\xff' * 32 + bytes.fromhex('cc55aa33') + b'\xaa' * 460
    commands = audit.expected_background(transport, data)[:-6]
    # TD emits the QE wait as two separate commands; preserve file commands.
    index = commands.index(('RUNTEST', 100000))
    commands[index:index + 1] = [('RUNTEST', 50000), ('RUNTEST', 50000)]
    commands += [svf.scan('SIR', 8, 255), svf.scan('SIR', 8, 1), ('RUNTEST', 20)]
    for _ in range(4):
        commands += [svf.scan('SIR', 8, 255), ('RUNTEST', 20)]
    commands += [svf.scan('SIR', 8, 255), ('RUNTEST', 10000), svf.scan('SIR', 8, 0x20),
                 svf.scan('SDR', 32, 0, 0, 0), svf.scan('SIR', 8, 0x80),
                 svf.scan('SDR', 64, 0xa5), ('RUNTEST', 200)]
    return data, commands, encode(commands)


class StopAfterRefresh(BaseException):
    pass


class FakeJtag(transport.Jtag):
    instances = []
    mismatch = False
    bad_id = False
    interrupt_refresh = False

    def __init__(self, deadline, guard):
        self.deadline, self.guard = deadline, guard
        self.records, self.blocks, self.closed = [], [], False
        self.responses = {(c.args[0], c.args[1]): c.args[2] for c in self.plan['commands']
                          if c.kind == 'SDR' and c.args[3]}
        self.instances.append(self)

    def scan(self, count, value, instruction=False):
        self.guard()
        self.records.append(('SIR' if instruction else 'SDR', count, value))
        result = self.responses.get((count, value), 0)
        if self.bad_id and count == 32:
            return 0
        if self.mismatch and count == 2089:
            result ^= 1 << 41
        return result

    def clocks(self, bits):
        self.guard()
        if self.clock[0] >= self.deadline:
            raise TimeoutError('fake deadline')
        self.blocks.append(list(bits))
        if self.interrupt_refresh and len(bits) == 4096:
            raise StopAfterRefresh()
        return bytes(bits)

    def run(self, count):
        self.guard()
        self.records.append(('RUNTEST', count))

    def close(self):
        self.closed = True


class PlaybackTests(unittest.TestCase):
    def setUp(self):
        self.data, self.commands, self.raw = fixture()
        self.plan = svf.validate(self.raw, CFG)

    def test_valid_complete_profile(self):
        self.assertEqual(self.plan['pages'], 2)
        self.assertEqual(self.plan['sectors'], 1)
        self.assertEqual(self.plan['flashSha256'], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(self.plan['commands'][self.plan['refreshStart'] + 1].key, svf.scan('SIR', 8, 1))

    def test_reject_changed_or_unverified_profiles_before_hardware(self):
        mutations = []
        for index in (17, 22, self.plan['eraseStart'] + 1, self.plan['writeStart'] + 1,
                      self.plan['verifyStart'], self.plan['refreshStart'] + 2):
            changed = list(self.commands)
            command = list(changed[index])
            command[2 if command[0] in ('SIR', 'SDR') else 1] ^= 1
            changed[index] = tuple(command)
            mutations.append(encode(changed))
        changed = list(self.commands)
        index = self.plan['verifyStart']
        command = list(changed[index]); command[4] = 0; changed[index] = tuple(command)
        mutations += [encode(changed), encode(self.commands[:-18]),
                      encode(self.commands[:25] + [svf.scan('SIR', 8, 1)] + self.commands[25:]),
                      b'not a bitstream', self.raw[:-2], b'x' * (svf.MAX_SVF + 1),
                      self.raw.replace(b'ENDDR IDLE;', b'ENDDR DRPAUSE;'),
                      self.raw.replace(b'TRST OFF;', b'TRST ON;')]
        for raw in mutations:
            with self.subTest(size=len(raw)), self.assertRaises((ValueError, UnicodeError)):
                svf.validate(raw, CFG)
        for cfg in ({}, dict(CFG, running_persist_bit_confirmed=False),
                    dict(CFG, approved_feature_codes=['00' * 18])):
            with self.assertRaises(ValueError):
                svf.validate(self.raw, cfg)
        self.assertFalse(hasattr(transport, 'update'))

    def test_golden_guard_and_feature_ambiguity(self):
        with mock.patch.object(svf, 'parse', return_value=[
                svf.Command('SDR', (2088, 0, None, None), 1)] * 1537):
            with self.assertRaisesRegex(ValueError, 'Golden'):
                svf.validate(self.raw, CFG)
        cfg = dict(CFG, approved_feature_codes=[FEATURE, FEATURE[:32] + '0000'])
        with self.assertRaisesRegex(ValueError, 'uniquely'):
            svf.validate(self.raw, cfg)

    def run_worker(self, host=lambda: True, checkpoint_error=False):
        clock = [100.0]
        receipts, events = [], []
        FakeJtag.plan, FakeJtag.clock = self.plan, clock
        def checkpoint(value):
            if checkpoint_error:
                raise OSError('offline receipt failure')
            receipts.append(dict(value))
        def sleep(seconds):
            raise StopAfterRefresh()
        timer = types.SimpleNamespace(monotonic=lambda: clock[0], time=lambda: 1791773334 + clock[0], sleep=sleep)
        fake_path = lambda path: types.SimpleNamespace(open=lambda mode: io.BytesIO(self.raw))
        with mock.patch.multiple(svf, Jtag=FakeJtag, configuration=lambda: CFG,
                boot_id=lambda: 'old', host_off=host, checkpoint=checkpoint, Path=fake_path,
                event=lambda *args, **kwargs: events.append((args, kwargs)),
                trace=lambda message: None, diagnostic_pause=lambda *args: None, time=timer):
            try:
                svf.update('offline.svf', 'offline', 500, hashlib.sha256(self.raw).hexdigest())
            except StopAfterRefresh:
                pass
        return receipts, events

    def test_playback_and_exact_refresh_tail(self):
        receipts, events = self.run_worker()
        jtag = FakeJtag.instances[-1]
        self.assertTrue(jtag.closed)
        self.assertTrue(receipts[0]['flashVerified'])
        self.assertFalse(receipts[0]['refreshSequenceCompleted'])
        self.assertTrue(receipts[1]['refreshSequenceCompleted'])
        self.assertEqual(receipts[0]['deadlineUnix'], receipts[1]['deadlineUnix'])
        # Initial preflight reset + file STATE RESET/IDLE precede tail batches.
        tail = [bit for block in jtag.blocks[3:] for bit in block]
        expected = []
        for c in self.plan['commands'][self.plan['refreshStart']:]:
            if c.kind in ('SIR', 'SDR'):
                expected += transport.Jtag.scan_bits(c.args[0], c.args[1], c.kind == 'SIR')
            else:
                expected += [0] * c.args[0]
        self.assertEqual(tail, expected)
        self.assertEqual(len(tail), 10532)
        self.assertEqual(list(map(len, jtag.blocks[3:])), [4096, 4096, 2340])
        self.assertIn(('RUNTEST', 150000), jtag.records)
        self.assertEqual(sum(record[:2] == ('SDR', 2089) for record in jtag.records), 2)

    def test_readback_or_id_mismatch_blocks_refresh(self):
        for attribute in ('mismatch', 'bad_id'):
            setattr(FakeJtag, attribute, True)
            try:
                with self.assertRaises((RuntimeError, ValueError)):
                    self.run_worker()
                jtag = FakeJtag.instances[-1]
                self.assertTrue(jtag.closed)
                self.assertFalse(any(len(b) == 4096 for b in jtag.blocks))
            finally:
                setattr(FakeJtag, attribute, False)

    def test_host_on_before_refresh_blocks_tail(self):
        checks = []
        def host():
            checks.append(1)
            return len(checks) < 3
        with self.assertRaisesRegex(RuntimeError, 'Host is no longer Off'):
            self.run_worker(host)
        self.assertFalse(any(len(b) == 4096 for b in FakeJtag.instances[-1].blocks))

    def test_receipt_failure_blocks_refresh(self):
        with self.assertRaisesRegex(OSError, 'receipt failure'):
            self.run_worker(checkpoint_error=True)
        self.assertFalse(any(len(b) == 4096 for b in FakeJtag.instances[-1].blocks))

    def test_interrupted_refresh_retains_verified_but_unconfirmed_receipt(self):
        FakeJtag.interrupt_refresh = True
        try:
            receipts, events = self.run_worker()
            self.assertEqual(len(receipts), 1)
            self.assertTrue(receipts[0]['flashVerified'])
            self.assertFalse(receipts[0]['refreshSequenceCompleted'])
        finally:
            FakeJtag.interrupt_refresh = False

    def test_trace_every_command_and_zero_mask_is_not_done(self):
        messages = []
        jtag = types.SimpleNamespace(scan=lambda *args: 0xffffffff)
        cmd = svf.Command('SDR', (32, 0, 0, 0), 5078)
        with mock.patch.object(svf, 'trace', messages.append):
            svf.execute(jtag, 0, cmd, self.plan)
        self.assertIn('line=5078', messages[0])
        self.assertIn('no comparison; not a DONE check', messages[0])
        self.assertIn('unverified status', messages[1])

    def test_real_vendor_export_if_supplied(self):
        path = os.environ.get('CEB_SVF_REVIEW_FILE')
        if not path:
            self.skipTest('Set CEB_SVF_REVIEW_FILE for a supplied vendor export')
        plan = svf.validate(Path(path).read_bytes(), CFG)
        self.assertEqual(plan['sha256'], '137b2fd90b24821e304c9c2c6cd9a56680763a5906e9e6f59c702525edfe22ad')
        self.assertEqual((plan['pages'], plan['sectors']), (1199, 75))
        self.assertEqual(plan['commands'][plan['refreshStart']].line, 5061)
        self.assertEqual(plan['commands'][plan['refreshStart'] + 1].line, 5063)

    def test_full_vendor_playback_if_supplied(self):
        path = os.environ.get('CEB_SVF_REVIEW_FILE')
        if not path:
            self.skipTest('Set CEB_SVF_REVIEW_FILE for full supplied SVF playback on a fake transport')
        self.raw = Path(path).read_bytes()
        self.plan = svf.validate(self.raw, CFG)
        receipts, events = self.run_worker()
        self.assertEqual(receipts[0]['verifiedPages'], 1199)
        self.assertEqual(sum(record[:2] == ('SDR', 2088) for record in FakeJtag.instances[-1].records), 1199)
        self.assertEqual(sum(record[:2] == ('SDR', 2089) for record in FakeJtag.instances[-1].records), 1199)
        self.assertTrue(receipts[1]['refreshSequenceCompleted'])


def service_module():
    class Interface:
        def __init__(self, name):
            pass
        def emit_properties_changed(self, values):
            pass
    for name in ('dbus_fast', 'dbus_fast.aio', 'dbus_fast.constants', 'dbus_fast.service'):
        sys.modules[name] = types.ModuleType(name)
    sys.modules['dbus_fast'].DBusError = type('DBusError', (RuntimeError,), {})
    sys.modules['dbus_fast'].Message = lambda **kwargs: types.SimpleNamespace(**kwargs)
    sys.modules['dbus_fast.aio'].MessageBus = object
    constants = sys.modules['dbus_fast.constants']
    for name in ('BusType', 'MessageType', 'NameFlag', 'PropertyAccess', 'RequestNameReply'):
        setattr(constants, name, types.SimpleNamespace(READ=0, SYSTEM=0, ERROR=1,
                                                       DO_NOT_QUEUE=0, PRIMARY_OWNER=0))
    interface = sys.modules['dbus_fast.service']
    interface.ServiceInterface = Interface
    interface.dbus_property = lambda **kwargs: property
    interface.method = lambda: lambda function: function
    return load('offline_cpld_service', FILES / 'ceb-gnrd-cpld-update.py')


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = service_module()

    def setUp(self):
        self.fs, self.checkpoints, self.fds = {}, [], {}
        fs = self.fs
        class MemoryPath:
            def __init__(self, name): self.name = str(name)
            def __str__(self): return self.name
            def __truediv__(self, name): return MemoryPath(self.name + '/' + name)
            def mkdir(self, **kwargs): pass
            def exists(self): return self.name in fs
            def stat(self): return types.SimpleNamespace(st_size=len(fs[self.name]))
            def read_text(self): return fs[self.name].decode()
            def unlink(self, **kwargs): fs.pop(self.name, None)
        self.Path = MemoryPath
        self.patches = mock.patch.multiple(self.service, Path=MemoryPath,
            RUN=MemoryPath('ram'), RECEIPT=MemoryPath('receipt'), DEVICE='fake-jtag',
            configuration=lambda: CFG, boot_id=lambda: 'new-boot',
            checkpoint=lambda value: self.checkpoints.append(dict(value)), console_log=lambda message: None)
        self.patches.start()
        self.fs['fake-jtag'] = b'fake'

    def tearDown(self):
        self.patches.stop()

    def test_start_svf_upload_and_cancel(self):
        fds, fs = self.fds, self.fs
        def open_memory(path, *args):
            fd = len(fds) + 100
            fds[fd] = str(path)
            return fd
        class Writer(io.BytesIO):
            def __init__(self, path): super().__init__(); self.path = path
            def close(self): fs[self.path] = self.getvalue(); super().close()
        def task(coroutine):
            coroutine.close()
            return types.SimpleNamespace(done=lambda: False)
        _, _, raw = fixture()
        u = self.service.Update(None)
        with mock.patch.object(self.service.os, 'open', open_memory), \
             mock.patch.object(self.service.os, 'fdopen', lambda fd, mode: Writer(fds[fd])), \
             mock.patch.object(self.service.os, 'close', lambda fd: None), \
             mock.patch.object(self.service.os, 'O_NOFOLLOW', 0, create=True), \
             mock.patch.object(self.service.os, 'O_CLOEXEC', 0, create=True), \
             mock.patch.object(self.service.asyncio, 'create_task', task):
            job = u.Start(base64.b64encode(raw).decode())
            self.assertEqual(fs['ram/image.svf'], raw)
            self.assertEqual(u.state['programmingFormat'], 'svf')
            self.assertEqual(u.state['sha256'], hashlib.sha256(raw).hexdigest())
            self.assertEqual(json.loads(u.Status)['maxUploadBytes'], 4194304)
            self.assertEqual(u.state['job'], job)
            self.assertTrue(u.Cancel())
            u.state['phase'] = 'Writing'
            self.assertFalse(u.Cancel())
            with self.assertRaises(RuntimeError):
                u.Start(base64.b64encode(raw).decode())
            u.unlock()

    def test_invalid_upload_rejected_without_saving_or_task(self):
        u = self.service.Update(None)
        with mock.patch.object(self.service.asyncio, 'create_task', side_effect=AssertionError('Invalid upload started a worker')):
            for encoded in ('?', base64.b64encode(b'bad bitstream').decode(),
                            'A' * (4 * ((svf.MAX_SVF + 2) // 3) + 1)):
                with self.assertRaises(RuntimeError):
                    u.Start(encoded)
        self.assertNotIn('ram/image.svf', self.fs)

    def test_recovery_requires_verified_receipt_new_boot_and_original_deadline(self):
        now = self.service.time.time()
        base = dict(job='offline', phase='AwaitBmcReboot', bootId='old', flashVerified=True,
                    armedUnix=now - 1, deadlineUnix=now + 60, refreshSequenceCompleted=False)
        for updates, expected in (({}, 'Completed'), ({'flashVerified': False}, 'Failed'),
                                  ({'bootId': 'new-boot'}, 'Failed'), ({'deadlineUnix': now - 10}, 'Failed')):
            self.fs['receipt'] = json.dumps(dict(base, **updates)).encode()
            u = self.service.Update(None)
            self.assertEqual(u.state['phase'], expected)
            if expected == 'Completed':
                self.assertIn('completion was not recorded', u.state['detail'])

    def test_worker_arguments_and_delayed_progress_do_not_overwrite_receipt(self):
        u = self.service.Update(None)
        u.state.update(job='offline', phase='WaitingForHostOff', sha256='digest', programmingFormat='svf')
        u.deadline = self.service.time.monotonic() + 500
        u.unlock = lambda: None
        output = iter([dict(phase='Verifying', progress=93, detail='verified', flashVerified=True),
                       dict(phase='AwaitBmcReboot', progress=95, detail='refresh'), None])
        calls = []
        async def readline():
            value = next(output)
            return json.dumps(value).encode() + b'\n' if value else b''
        async def wait(): return 0
        process = types.SimpleNamespace(stdout=types.SimpleNamespace(readline=readline),
                                        returncode=0, wait=wait)
        async def start(*args, **kwargs): calls.append(args); return process
        async def idle(*args): pass
        async def thread(function): return function()
        async def wait_for(coroutine, timeout): return await coroutine
        async def not_busy(): return False
        u.updater_busy = not_busy
        with mock.patch.object(self.service.asyncio, 'sleep', idle), \
             mock.patch.object(self.service.asyncio, 'to_thread', thread), \
             mock.patch.object(self.service.asyncio, 'wait_for', wait_for), \
             mock.patch.object(self.service.asyncio, 'create_subprocess_exec', start), \
             mock.patch.object(self.service, 'host_off', lambda: True):
            coroutine = u.run_job(self.Path('ram/image.svf'), 'offline')
            with self.assertRaises(StopIteration):
                coroutine.send(None)
        self.assertEqual(calls[0][1], '/usr/libexec/cpld_svf.py')
        self.assertEqual(calls[0][-1], 'digest')
        self.assertEqual([item['phase'] for item in self.checkpoints], ['Preflight'])
        self.assertEqual(u.state['phase'], 'AwaitBmcReboot')


if __name__ == '__main__':
    unittest.main()
