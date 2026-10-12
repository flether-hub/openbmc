#!/usr/bin/python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded CPLD update job service. Web calls use the admin-only D-Bus REST API."""
import asyncio
import binascii
import fcntl
import json
import logging
import os
from pathlib import Path
import time

from dbus_fast import DBusError, Message
from dbus_fast.aio import MessageBus
from dbus_fast.constants import BusType, MessageType, NameFlag, PropertyAccess, RequestNameReply
from dbus_fast.service import ServiceInterface, dbus_property, method
from cpld_jtag import (DEVICE, RECEIPT, boot_id,
                       checkpoint, configuration, console_debug_enabled,
                       console_log, host_off, require_background)
from cpld_svf import MAX_SVF, validate

LOG = logging.getLogger('ceb-gnrd-cpld-update')

SERVICE = 'com.ctopai.CebGnrd.CpldUpdate'
OBJECT = '/xyz/openbmc_project/software/cpld_update'
INTERFACE = 'com.ctopai.CebGnrd.CpldUpdate'
RUN = Path('/run/ceb-gnrd-cpld-update')
ACTIVE = {'WaitingForHostOff', 'Preflight', 'Erasing', 'Writing', 'Verifying', 'AwaitBmcReboot'}


class Update(ServiceInterface):
    def __init__(self, bus):
        super().__init__(INTERFACE)
        self.bus = bus
        self.task = None
        self.cancel_requested = False
        self.locks = []
        self.deadline = 0.0
        self.state = dict(phase='Idle', progress=0, detail='Ready', job='', bootId=boot_id())
        if RECEIPT.exists():
            try:
                if RECEIPT.stat().st_size > 8192:
                    raise ValueError('Oversize upgrade receipt')
                previous = json.loads(RECEIPT.read_text())
                if previous.get('phase') in ACTIVE:
                    if (previous.get('phase') == 'AwaitBmcReboot' and
                            previous.get('flashVerified') is True and
                            previous.get('bootId') != boot_id() and
                            isinstance(previous.get('armedUnix'), (int, float)) and
                            isinstance(previous.get('deadlineUnix'), (int, float)) and
                            previous['armedUnix'] - 5 <= time.time() <= previous['deadlineUnix']):
                        previous.update(phase='Completed', progress=100,
                                        detail='Flash verified; new BMC boot detected. CPLD running version is not read back.',
                                        recoveredBootId=boot_id())
                        if previous.get('refreshSequenceCompleted') is not True:
                            previous['detail'] += ' JTAG Refresh sequence completion was not recorded.'
                    else:
                        previous.update(phase='Failed', detail='Previous update was interrupted or its recovery deadline expired; automatic reload is blocked')
                    checkpoint(previous)
                self.state = previous
                LOG.info('CPLD recovered job=%s phase=%s flashVerified=%s refreshSequenceCompleted=%s',
                         previous.get('job'), previous.get('phase'),
                         previous.get('flashVerified'), previous.get('refreshSequenceCompleted'))
                console_log(f'CPLD-SERVICE recovered job={previous.get("job")} '
                            f'phase={previous.get("phase")} flashVerified={previous.get("flashVerified")} '
                            f'refreshSequenceCompleted={previous.get("refreshSequenceCompleted")}')
            except Exception as exc:
                self.state.update(phase='Failed', detail=f'Cannot read upgrade receipt: {exc}')

    def ready(self):
        try:
            cfg = configuration()
            features = cfg.get('approved_feature_codes')
            if not isinstance(features, list) or not features:
                return False
            require_background(features[0].upper(), cfg)
            return Path(DEVICE).exists()
        except Exception:
            return False

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> 's':
        value = dict(self.state, ready=self.ready(), timeoutSeconds=600,
                     supportedFormat='svf', maxUploadBytes=MAX_SVF,
                     currentBootId=boot_id(),
                     remainingSeconds=max(0, int(self.deadline - time.monotonic())))
        return json.dumps(value, separators=(',', ':'))

    def publish(self, **values):
        previous_phase = self.state.get('phase')
        self.state.update(values)
        if (self.state.get('phase') != previous_phase or values.get('flashVerified') or
                values.get('refreshSequenceCompleted') or console_debug_enabled()):
            LOG.info('CPLD job=%s phase=%s progress=%s detail=%s',
                     self.state.get('job'), self.state.get('phase'),
                     self.state.get('progress'), self.state.get('detail'))
            console_log(f'CPLD-SERVICE [{time.monotonic():.6f}] job={self.state.get("job")} '
                        f'phase={self.state.get("phase")} progress={self.state.get("progress")} '
                        f'detail={self.state.get("detail")}')
        self.emit_properties_changed({'Status': self.Status})

    @method()
    def Start(self, encoded: 's') -> 's':
        if self.task is not None and not self.task.done():
            raise DBusError(INTERFACE + '.Busy', 'Another CPLD update is active')
        image = None
        job = None
        try:
            accepted_deadline = time.monotonic() + 600
            if len(encoded) > 4 * ((MAX_SVF + 2) // 3):
                raise ValueError('SVF exceeds 4 MiB')
            raw = binascii.a2b_base64(encoded, strict_mode=True)
            cfg = configuration()
            plan = validate(raw, cfg)
            if not Path(DEVICE).exists():
                raise ValueError('JTAG Master-1 device is unavailable')
            RUN.mkdir(mode=0o700, parents=True, exist_ok=True)
            # Same BIOS lock as the existing updater, plus a CPLD singleton.
            for name in ('ceb-gnrd-bios-update', 'ceb-gnrd-cpld-update'):
                Path('/run/lock').mkdir(exist_ok=True)
                fd = os.open(f'/run/lock/{name}.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except Exception:
                    os.close(fd)
                    raise ValueError('BIOS or CPLD update is already active')
                self.locks.append(fd)
            job = os.urandom(16).hex()
            image = RUN / 'image.svf'
            fd = os.open(image, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as output:
                output.write(raw)
            self.deadline = accepted_deadline
            if time.monotonic() >= self.deadline:
                raise TimeoutError('The upgrade deadline expired while validating the SVF')
            self.state = dict(job=job, phase='WaitingForHostOff', progress=0,
                              detail='Please shut down the host. Waiting for stable Off state before SVF playback.',
                              sha256=plan['sha256'], flashSha256=plan['flashSha256'],
                              feature=plan['feature'], bootId=boot_id(),
                              flashVerified=False, programmingFormat='svf')
            checkpoint(self.state)
            self.publish()
            self.cancel_requested = False
            self.task = asyncio.create_task(self.run_job(image, job))
            return job
        except Exception as exc:
            LOG.warning('CPLD Start rejected (%s): %s', type(exc).__name__, str(exc)[:512])
            console_log(f'CPLD-SERVICE Start rejected {type(exc).__name__}: {str(exc)[:512]}')
            self.unlock()
            self.state.update(lastStartError=str(exc)[:512], lastStartErrorType=type(exc).__name__)
            if image is not None:
                try:
                    image.unlink(missing_ok=True)
                except OSError:
                    pass  # One bounded RAM file; cleanup on next attempt/reboot.
            if job is not None and self.state.get('job') == job:
                self.publish(phase='Failed', detail=str(exc)[:512])
            raise DBusError(INTERFACE + '.Blocked', str(exc)) from exc

    @method()
    def Cancel(self) -> 'b':
        # Cancellation after an erase could strand Flash; only the waiting
        # phase is cancellable. Host-on/timeout remain mandatory stop guards.
        if self.task is not None and not self.task.done() and self.state['phase'] == 'WaitingForHostOff':
            # A Task cancelled before its first turn does not execute finally.
            # Signal the coroutine instead, so image and locks are released.
            self.cancel_requested = True
            return True
        return False

    def unlock(self):
        for fd in self.locks:
            os.close(fd)
        self.locks.clear()

    async def updater_busy(self):
        reply = await asyncio.wait_for(self.bus.call(Message(
            destination='xyz.openbmc_project.Software.BMC.Updater',
            path='/xyz/openbmc_project/software',
            interface='org.freedesktop.DBus.ObjectManager', member='GetManagedObjects')), 3)
        if reply.message_type == MessageType.ERROR:
            raise RuntimeError('Cannot check BMC firmware updater; CPLD update blocked')
        for interfaces in reply.body[0].values():
            props = interfaces.get('xyz.openbmc_project.Software.Activation', {})
            activation = props.get('Activation')
            if activation and activation.value.endswith('.Activating'):
                return True
        return False

    async def run_job(self, image, job):
        process = None
        deadline = self.deadline
        try:
            if self.cancel_requested:
                raise asyncio.CancelledError
            if await self.updater_busy():
                raise RuntimeError('BMC firmware update is active')
            stable = 0
            while stable < 3:
                if self.cancel_requested:
                    raise asyncio.CancelledError
                if time.monotonic() >= deadline:
                    raise TimeoutError('Host did not shut down within the 10-minute update timeout')
                off = await asyncio.to_thread(host_off)
                stable = stable + 1 if off else 0
                await asyncio.sleep(1)
            if self.cancel_requested:
                raise asyncio.CancelledError
            if await self.updater_busy():
                raise RuntimeError('BMC firmware update became active')
            if self.cancel_requested:
                raise asyncio.CancelledError
            if time.monotonic() >= deadline:
                raise TimeoutError('The 10-minute update timeout expired before programming')
            self.publish(phase='Preflight', progress=3, detail='Host is Off; checking JTAG')
            checkpoint(self.state)
            process = await asyncio.create_subprocess_exec(
                '/usr/bin/python3', '/usr/libexec/cpld_svf.py', str(image), job,
                str(max(0.1, deadline - time.monotonic())),
                self.state['sha256'],
                # Diagnostics go directly to the service journal; do not put
                # them in an undrained pipe that can block the JTAG worker.
                stdout=asyncio.subprocess.PIPE)

            async def messages():
                while line := await process.stdout.readline():
                    value = json.loads(line)
                    self.publish(**value)
                    # Once launched, the worker owns the verified receipt.
                    # Delayed progress must not overwrite its pre-Refresh proof.
                await process.wait()
                if process.returncode:
                    raise RuntimeError(self.state.get('detail') or
                                       f'JTAG worker failed (exit {process.returncode}); see service journal')

            await asyncio.wait_for(messages(), max(0.1, deadline - time.monotonic()))
        except asyncio.CancelledError:
            self.publish(phase='Cancelled', progress=0, detail='Update cancelled before programming')
            checkpoint(self.state)
        except Exception as exc:
            self.publish(phase='Failed', detail=str(exc)[:512])
            checkpoint(self.state)
        finally:
            if process is not None and process.returncode is None:
                process.kill()
                await process.wait()
            try:
                image.unlink(missing_ok=True)
            finally:
                self.unlock()


async def main():
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    updater = Update(bus)
    bus.export(OBJECT, updater)
    reply = await bus.request_name(SERVICE, NameFlag.DO_NOT_QUEUE)
    if reply != RequestNameReply.PRIMARY_OWNER:
        raise RuntimeError('CPLD update service is already owned')
    await bus.wait_for_disconnect()


if __name__ == '__main__':
    asyncio.run(main())
