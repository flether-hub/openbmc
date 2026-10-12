#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline .bit programming/service tests. All JTAG, Flash and paths are fake."""
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
player = load('cpld_jtag', FILES / 'cpld_jtag.py')
FEATURE = 'FFDD66BB22FFFFFFA2FFFFFFFFFFFFFF9368'
CFG = dict(running_persist_bit_confirmed=True, confirmation_reference='offline', approved_feature_codes=[FEATURE])


def image(payload=None):
    if payload is None:
        payload = b'\xff' * 32 + bytes.fromhex('cc55aa33') + b'\xaa' * 460
    header = f'# Architecture: ef3_9\n# Package: EF3L90CG400B\n# Feature code: {FEATURE}\n\n'.encode()
    return header + b''.join((len(payload[i:i+4096]) * 8).to_bytes(2, 'big') + payload[i:i+4096]
                             for i in range(0, len(payload), 4096))


class FakeJtag(player.Jtag):
    plan = None
    instances = []
    mismatch = False
    status_ff = False
    bad_id = False
    close_error = False
    expire_write = False

    def __init__(self, deadline, guard):
        self.deadline, self.guard = deadline, guard
        self.memory = bytearray(self.plan['data'])
        self.records, self.busy, self.wel, self.writes, self.closed = [], 0, False, 0, False
        self.instances.append(self)

    def clocks(self, bits):
        self.guard()
        self.records.append(('CLOCKS', len(bits)))
        return bytes(bits)

    def scan(self, count, value, instruction=False):
        self.guard()
        self.records.append(('SIR' if instruction else 'SDR', count, value))
        if count == 32 and value == 0:
            return 0 if self.bad_id else player.IDCODE
        return 0

    def run(self, count):
        self.guard()
        self.records.append(('RUN', count))

    def spi(self, data, extra_bit=False):
        self.guard()
        command = data[0]
        self.records.append(('SPI', bytes(data), extra_bit))
        if command == 5:
            if self.status_ff:
                status = 0xff
            elif self.busy:
                self.busy -= 1
                status = 1
            else:
                status = 2 if self.wel else 0
            return player.REVERSE[status] << 17
        address = int.from_bytes(data[1:4], 'big')
        if command in (2, 0x20):
            if not self.wel:
                raise AssertionError('Write/erase without WEL')
            self.wel, self.busy = False, 2
            if command == 0x20:
                self.memory[address:address+4096] = b'\xff' * 4096
            else:
                self.memory[address:address+256] = data[4:]
                self.writes += 1
                if self.expire_write:
                    self.clock[0] += 600
            return 0
        if command == 3:
            read = bytes(self.memory[address:address+256])
            if self.mismatch and self.writes == self.plan['pages'] and address == (self.plan['pages'] - 1) * 256:
                read = bytes([read[0] ^ 1]) + read[1:]
            return int.from_bytes(read.translate(player.REVERSE), 'little') << 41
        raise AssertionError(f'Unexpected SPI opcode {command}')

    def wren(self):
        self.guard()
        self.records.append(('WREN',))
        self.wel = True

    def close(self):
        self.closed = True
        self.records.append(('CLOSE',))
        if self.close_error:
            raise OSError('fake close error')


class BitTests(unittest.TestCase):
    def setUp(self):
        self.raw = image()
        self.plan = player.bit_plan(self.raw, CFG)
        for attr in ('mismatch', 'status_ff', 'bad_id', 'close_error', 'expire_write'):
            setattr(FakeJtag, attr, False)

    def run_worker(self, host=lambda: True, receipt_error=False, digest=None):
        clock, receipts, events = [100.0], [], []
        FakeJtag.plan, FakeJtag.clock = self.plan, clock
        def checkpoint(value):
            if receipt_error:
                raise OSError('fake receipt error')
            receipts.append(dict(value))
        def sleep(seconds): clock[0] += seconds
        timer = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep)
        fake_path = lambda path: types.SimpleNamespace(open=lambda mode: io.BytesIO(self.raw))
        with mock.patch.multiple(player, Jtag=FakeJtag, configuration=lambda: CFG, Path=fake_path,
                boot_id=lambda: 'same-boot', host_off=host, checkpoint=checkpoint,
                trace=lambda *args: None, time=timer,
                event=lambda *args, **kwargs: events.append((args, kwargs))):
            player.update('offline.bit', 'offline', 500, digest or hashlib.sha256(self.raw).hexdigest())
        return receipts, events

    def test_complete_without_refresh_or_reboot(self):
        receipts, events = self.run_worker()
        jtag = FakeJtag.instances[-1]
        self.assertTrue(jtag.closed)
        self.assertEqual(jtag.memory[:len(self.plan['data'])], self.plan['data'])
        self.assertEqual(receipts[0]['phase'], 'Completed')
        self.assertTrue(receipts[0]['flashVerified'])
        self.assertTrue(receipts[0]['activationRequired'])
        self.assertEqual(receipts[0]['activationMethod'], 'ACPowerCycle')
        self.assertFalse(receipts[0]['autoRefresh'])
        self.assertEqual(events[-1][0][:2], ('Completed', 100))
        instructions = [r[2] for r in jtag.records if r[0] == 'SIR']
        self.assertNotIn(1, instructions)
        self.assertNotIn(0x20, instructions)
        self.assertEqual(instructions[-1], 0x39)
        self.assertEqual(jtag.records[-1], ('CLOSE',))

    def test_bad_readback_id_status_close_or_timeout_cannot_complete(self):
        for attr in ('mismatch', 'bad_id', 'status_ff', 'close_error', 'expire_write'):
            with self.subTest(attr=attr):
                setattr(FakeJtag, attr, True)
                try:
                    with self.assertRaises((RuntimeError, ValueError, OSError, TimeoutError)):
                        self.run_worker()
                    self.assertTrue(FakeJtag.instances[-1].closed)
                finally:
                    setattr(FakeJtag, attr, False)

    def test_host_on_and_receipt_failure_block_success(self):
        with self.assertRaisesRegex(RuntimeError, 'Host'):
            self.run_worker(host=lambda: False)
        with self.assertRaisesRegex(OSError, 'receipt'):
            self.run_worker(receipt_error=True)

    def test_image_validation_and_digest(self):
        for raw in (b'bad', b'x' * (player.MAX_IMAGE + 1), self.raw[:-1],
                    self.raw.replace(b'EF3L90CG400B', b'EF3L40CG400B'),
                    image(b'\xff' * 32 + bytes.fromhex('cc55bb33') + b'\xaa' * 460)):
            if raw == self.raw:
                continue
            with self.assertRaises(ValueError): player.bit_plan(raw, CFG)
        for cfg in ({}, dict(CFG, running_persist_bit_confirmed=False), dict(CFG, approved_feature_codes=[])):
            with self.assertRaises(ValueError): player.bit_plan(self.raw, cfg)
        with self.assertRaisesRegex(ValueError, 'Golden'):
            player.bit_plan(image(b'\xff' * 32 + bytes.fromhex('cc55aa33') + bytes(player.PRIMARY_FLASH_LIMIT)), CFG)
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.run_worker(digest='wrong')

    def test_supplier_bit_if_supplied(self):
        name = os.environ.get('CEB_BIT_REVIEW_FILE')
        if not name: self.skipTest('Set CEB_BIT_REVIEW_FILE to audit a supplier image')
        self.raw = Path(name).read_bytes()
        self.plan = player.bit_plan(self.raw, CFG)
        self.assertEqual(self.plan['sha256'], 'd837f017b99cd2409d9cb2d81c4179d6b2ae77c668f0499ec1144d17f39b98bd')
        self.assertEqual((self.plan['pages'], self.plan['sectors']), (1199, 75))
        receipts, events = self.run_worker()
        self.assertEqual(receipts[0]['verifiedPages'], 1199)
        self.assertEqual(FakeJtag.instances[-1].writes, 1199)


def service_module():
    class Interface:
        def __init__(self, *args): pass
        def emit_properties_changed(self, *args): pass
    for name in ('dbus_fast', 'dbus_fast.aio', 'dbus_fast.constants', 'dbus_fast.service'):
        sys.modules[name] = types.ModuleType(name)
    sys.modules['dbus_fast'].DBusError = type('DBusError', (RuntimeError,), {})
    sys.modules['dbus_fast'].Message = lambda **kwargs: types.SimpleNamespace(**kwargs)
    sys.modules['dbus_fast.aio'].MessageBus = object
    for name in ('BusType', 'MessageType', 'NameFlag', 'PropertyAccess', 'RequestNameReply'):
        setattr(sys.modules['dbus_fast.constants'], name, types.SimpleNamespace(READ=0, SYSTEM=0, ERROR=1, DO_NOT_QUEUE=0, PRIMARY_OWNER=0))
    interface = sys.modules['dbus_fast.service']
    interface.ServiceInterface = Interface
    interface.dbus_property = lambda **kwargs: property
    interface.method = lambda: lambda function: function
    return load('offline_cpld_service', FILES / 'ceb-gnrd-cpld-update.py')


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.service = service_module()

    def setUp(self):
        self.fs, self.receipts = {}, []
        fs = self.fs
        class MemoryPath:
            def __init__(self, path): self.path = str(path)
            def __str__(self): return self.path
            def __truediv__(self, other): return MemoryPath(self.path + '/' + other)
            def exists(self): return self.path in fs
            def mkdir(self, **kwargs): pass
            def stat(self): return types.SimpleNamespace(st_size=len(fs[self.path]))
            def read_text(self): return fs[self.path].decode()
            def unlink(self, **kwargs): fs.pop(self.path, None)
        self.Path = MemoryPath
        self.patches = mock.patch.multiple(self.service, Path=MemoryPath, RUN=MemoryPath('ram'), RECEIPT=MemoryPath('receipt'),
            DEVICE='device', configuration=lambda: CFG, boot_id=lambda: 'new-boot',
            checkpoint=lambda value: self.receipts.append(dict(value)))
        self.patches.start()
        fs['device'] = b'fake'

    def tearDown(self): self.patches.stop()

    def test_start_bit_and_cancel(self):
        fds, fs = {}, self.fs
        def open_fd(path, *args):
            fd = len(fds) + 100; fds[fd] = str(path); return fd
        class Writer(io.BytesIO):
            def __init__(self, path): super().__init__(); self.path = path
            def close(self): fs[self.path] = self.getvalue(); super().close()
        def task(coroutine): coroutine.close(); return types.SimpleNamespace(done=lambda: False)
        u = self.service.Update(None)
        with mock.patch.object(self.service.os, 'open', open_fd), mock.patch.object(self.service.os, 'fdopen', lambda fd, mode: Writer(fds[fd])), \
             mock.patch.object(self.service.os, 'close', lambda *args: None), \
             mock.patch.object(self.service.os, 'O_NOFOLLOW', 0, create=True), \
             mock.patch.object(self.service.os, 'O_CLOEXEC', 0, create=True), \
             mock.patch.object(self.service.asyncio, 'create_task', task):
            job = u.Start(base64.b64encode(image()).decode())
            self.assertEqual(fs['ram/image.bit'], image())
            self.assertEqual(u.state['job'], job)
            self.assertEqual(json.loads(u.Status)['supportedFormat'], 'bit')
            self.assertEqual(json.loads(u.Status)['maxUploadBytes'], 1048576)
            self.assertTrue(u.Cancel())
            u.state['phase'] = 'Writing'; self.assertFalse(u.Cancel())
            u.unlock()

    def test_restart_discards_previous_job_receipts(self):
        for phase in ('Writing', 'AwaitBmcReboot', 'Verifying', 'Failed', 'Completed'):
            self.fs['receipt'] = json.dumps(dict(phase=phase, bootId='old', flashVerified=True)).encode()
            u = self.service.Update(None)
            self.assertEqual(u.state['phase'], 'Idle')
            self.assertEqual(u.state['progress'], 0)
            self.assertEqual(u.state['job'], '')
            self.assertNotIn('receipt', self.fs)

    def test_worker_exit_and_verified_completion_required(self):
        for rc, proof in ((0, True), (1, True), (0, False)):
            with self.subTest(rc=rc, proof=proof):
                u = self.service.Update(None)
                u.state.update(job='offline', phase='WaitingForHostOff', sha256='digest')
                u.deadline = self.service.time.monotonic() + 500
                queue = [dict(phase='Verifying', progress=99, detail='verified')]
                if proof: queue.append(dict(phase='Completed', progress=100, detail='AC required', flashVerified=True, activationRequired=True))
                calls = []
                async def readline(): return json.dumps(queue.pop(0)).encode() + b'\n' if queue else b''
                async def wait():
                    self.assertNotEqual(u.state['phase'], 'Completed')
                    process.returncode = rc
                process = types.SimpleNamespace(stdout=types.SimpleNamespace(readline=readline), returncode=None, wait=wait)
                async def start(*args, **kwargs): calls.append(args); return process
                async def idle(*args): pass
                async def thread(function): return function()
                async def wait_for(coroutine, timeout): return await coroutine
                async def busy(): return False
                u.updater_busy = busy
                with mock.patch.object(self.service.asyncio, 'create_subprocess_exec', start), \
                     mock.patch.object(self.service.asyncio, 'sleep', idle), mock.patch.object(self.service.asyncio, 'to_thread', thread), \
                     mock.patch.object(self.service.asyncio, 'wait_for', wait_for), \
                     mock.patch.object(self.service, 'host_off', lambda: True):
                    # All awaits are immediate fakes; do not create Windows'
                    # event-loop socketpair or perform any network operation.
                    coroutine = u.run_job(self.Path('ram/image.bit'), 'offline')
                    with self.assertRaises(StopIteration): coroutine.send(None)
                self.assertEqual(calls[0][1], '/usr/libexec/cpld_jtag.py')
                self.assertEqual(u.state['phase'], 'Completed' if rc == 0 and proof else 'Failed')

    def test_invalid_bit_and_base64_rejected(self):
        u = self.service.Update(None)
        for encoded in ('?', base64.b64encode(b'bad').decode(), 'A' * (4 * ((player.MAX_IMAGE + 2) // 3) + 1)):
            with self.assertRaises(RuntimeError): u.Start(encoded)
        self.assertNotIn('ram/image.bit', self.fs)


class JsonLimitTests(unittest.TestCase):
    def test_only_bit_start_gets_bounded_larger_json_limit(self):
        path = ROOT / 'recipes-phosphor/interfaces/files/0010-ceb-gnrd-cpld-bit-json-upload-limit.patch'
        text = path.read_text()
        self.assertIn('maxCpldBitBytes = 1U * 1024U * 1024U', text)
        self.assertIn('4U * ((maxCpldBitBytes + 2U) / 3U) + 64U', text)
        self.assertIn('objectPath == "/xyz/openbmc_project/software/cpld_update" &&', text)
        self.assertIn('methodName == "Start"', text)
        self.assertIn('isCpldStart ? maxCpldJsonBytes : 1048576U', text)
        self.assertIn('parseStringAsJson(req.body(), maxBodySize)', text)

    def test_max_bit_base64_envelope_fits_limit(self):
        raw = b'x' * player.MAX_IMAGE
        body = json.dumps({'data': [base64.b64encode(raw).decode()]}, separators=(',', ':')).encode()
        limit = 4 * ((player.MAX_IMAGE + 2) // 3) + 64
        self.assertEqual(limit, 1398168)
        self.assertGreater(len(body), 1048576)
        self.assertLessEqual(len(body), limit)
        self.assertEqual(base64.b64decode(json.loads(body)['data'][0]), raw)


if __name__ == '__main__': unittest.main()
