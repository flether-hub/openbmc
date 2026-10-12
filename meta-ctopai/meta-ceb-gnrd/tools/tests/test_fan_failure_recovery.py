#!/usr/bin/env python3
"""Offline regression checks of board fan services with fake D-Bus and clocks.

No sysfs, GPIO, real D-Bus, or physical fan is accessed. Async functions are
driven with immediate replies or explicit suspension points, without a loop.
"""
import ast
import logging
from pathlib import Path
from types import SimpleNamespace
import unittest

FILES = Path(__file__).resolve().parents[2] / "recipes-phosphor/fans/files"


class Interface:
    def __init__(self, name):
        self.name = name
        self.changes = []

    def emit_properties_changed(self, data):
        self.changes.append(data)


class Variant:
    def __init__(self, signature, value):
        self.signature = signature
        self.value = value


def load_service(name):
    tree = ast.parse((FILES / name).read_text(encoding="utf-8"))
    tree.body = [n for n in tree.body if not (
        isinstance(n, ast.ImportFrom) and (n.module or "").startswith("dbus_fast"))]
    ns = {
        "__name__": "offline_fan_test", "ServiceInterface": Interface,
        "PropertyAccess": SimpleNamespace(READ=1, READWRITE=2),
        "dbus_property": lambda **kw: property,
        "method": lambda **kw: (lambda fn: fn),
        "signal": lambda **kw: (lambda fn: fn), "Variant": Variant,
        "Message": lambda **kw: SimpleNamespace(**kw),
        "MessageType": SimpleNamespace(ERROR="error", METHOD_CALL="call"),
        "BusType": SimpleNamespace(SYSTEM=1), "MessageBus": None,
    }
    exec(compile(tree, str(FILES / name), "exec"), ns)
    ns["LOG"].setLevel(logging.CRITICAL)
    return ns


def complete(coro):
    try:
        unexpected = coro.send(None)
    except StopIteration as done:
        return done.value
    finally:
        coro.close()
    raise AssertionError("Unexpected asynchronous wait: %r" % (unexpected,))


class Pause:
    def __init__(self, value):
        self.value = value

    def __await__(self):
        yield self.value
        return None


async def sleep(seconds):
    await Pause(("sleep", seconds))


class ConfigBus:
    def __init__(self, ns, fixed=80.0):
        self.ns = ns
        self.config = {"/fan%d" % i: {"Name": "Fan%d Control" % i,
                                    "OutLimitMin": fixed, "OutLimitMax": fixed}
                       for i in range(6)}
        self.config["/zone"] = {"Name": "Zone 1", "MinThermalOutput": 30.0}
        self.fail_sets = set()
        self.restart_fail = False
        self.restart_calls = 0
        self.set_calls = 0

    async def call(self, bus, destination, path, interface, member, signature="", body=None):
        if member == "GetSubTree":
            requested = body[2][0]
            paths = ["/zone"] if requested == self.ns["ZONE_IFACE"] else ["/fan%d" % i for i in range(6)]
            return [{p: {"fake.entity.manager": [requested]} for p in paths if p in self.config}]
        if member == "GetAll":
            return [{k: Variant("s" if k == "Name" else "d", v)
                     for k, v in self.config[path].items()}]
        if member == "Get":
            return [Variant("d", self.config[path][body[1]])]
        if member == "Set":
            self.set_calls += 1
            key, value = body[1], body[2].value
            if (path, key, value) in self.fail_sets:
                raise RuntimeError("injected property write failure")
            self.config[path][key] = value
            return []
        if member == "RestartUnit":
            self.restart_calls += 1
            if self.restart_fail:
                raise RuntimeError("injected controller restart failure")
            return ["/fake/job"]
        raise AssertionError(member)


class FanSettingsRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_service("ceb-gnrd-fan-settings.py")
        self.bus = ConfigBus(self.ns)
        self.ns["call"] = self.bus.call
        self.saved = []
        self.ns["save_state"] = self.saved.append
        self.ns["delete_state"] = lambda: None
        self.iface = self.ns["FanSettings"](self.bus)

    def apply(self, fan=0, mode=1, duty=20, persist=0):
        return complete(self.iface.apply_fan(fan, mode, duty, persist))

    def test_failed_second_property_restores_old_limits(self):
        self.bus.fail_sets.add(("/fan0", "OutLimitMax", 20.0))
        self.assertFalse(self.apply())
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 80.0)
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMax"], 80.0)
        self.assertIsNone(self.iface.rollback_pending)
        self.assertFalse(self.iface.refresh_pending)

    def test_all_fans_roll_back_if_later_fan_write_fails(self):
        self.bus.fail_sets.add(("/fan2", "OutLimitMax", 20.0))
        self.assertFalse(self.apply(fan=0xFF))
        for index in range(6):
            self.assertEqual(self.bus.config["/fan%d" % index]["OutLimitMin"], 80.0)
            self.assertEqual(self.bus.config["/fan%d" % index]["OutLimitMax"], 80.0)

    def test_restart_failure_rolls_back_and_retains_retry(self):
        self.bus.restart_fail = True
        self.assertFalse(self.apply())
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 80.0)
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMax"], 80.0)
        self.assertIsNotNone(self.iface.rollback_pending)
        self.assertTrue(self.iface.refresh_pending)
        self.bus.restart_fail = False
        complete(self.ns["restore_pending_configuration"](self.bus, self.iface))
        self.assertIsNone(self.iface.rollback_pending)
        self.assertFalse(self.iface.refresh_pending)

    def test_zone_failure_rolls_back_controller_and_zone(self):
        self.bus.config["/zone"]["MinThermalOutput"] = 60.0
        self.bus.fail_sets.add(("/zone", "MinThermalOutput", 30.0))
        self.assertFalse(self.apply())
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 80.0)
        self.assertEqual(self.bus.config["/zone"]["MinThermalOutput"], 60.0)

    def test_missing_target_is_rejected_before_any_write(self):
        del self.bus.config["/fan2"]
        self.assertFalse(self.apply(fan=0xFF))
        self.assertEqual(self.bus.set_calls, 0)
        self.assertEqual(self.bus.restart_calls, 0)

    def test_persistence_failure_rolls_back_runtime_and_persist_flag(self):
        def fail_save(state):
            raise OSError("injected disk full")
        self.ns["save_state"] = fail_save
        self.assertFalse(self.apply(persist=1))
        self.assertFalse(self.iface.persist)
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 80.0)
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMax"], 80.0)

    def test_failed_rollback_is_retried_without_persistent_settings(self):
        self.bus.fail_sets.update({("/fan0", "OutLimitMax", 20.0),
                                  ("/fan0", "OutLimitMin", 80.0)})
        self.assertFalse(self.apply())
        self.assertIsNotNone(self.iface.rollback_pending)
        self.bus.fail_sets.clear()
        self.ns["load_state"] = lambda: None
        self.ns["asyncio"] = SimpleNamespace(sleep=sleep)
        task = self.ns["maintain"](self.bus, self.iface)
        try:
            self.assertEqual(task.send(None), ("sleep", 30))
            self.assertIsNone(self.iface.rollback_pending)
            self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 80.0)
            self.assertFalse(self.iface.refresh_pending)
        finally:
            task.close()

    def test_stored_restart_failure_retried_when_values_already_match(self):
        stored = {"persist": True, "controllers": {
            "Fan0 Control": {"OutLimitMin": 20.0, "OutLimitMax": 20.0}}}
        self.bus.restart_fail = True
        with self.assertRaises(RuntimeError):
            complete(self.ns["apply_stored"](self.bus, stored, self.iface))
        self.assertTrue(self.iface.refresh_pending)
        self.bus.restart_fail = False
        self.assertEqual(complete(self.ns["apply_stored"](self.bus, stored, self.iface)), 0)
        self.assertEqual(self.bus.restart_calls, 2)
        self.assertFalse(self.iface.refresh_pending)
        complete(self.ns["apply_stored"](self.bus, stored, self.iface))
        self.assertEqual(self.bus.restart_calls, 2, "unchanged healthy settings must not restart periodically")

    def test_maintenance_preserves_restart_retry_after_partial_restore(self):
        stored = {"persist": True, "controllers": {
            "Fan0 Control": {"OutLimitMin": 20.0, "OutLimitMax": 20.0}}}
        self.ns["load_state"] = lambda: stored
        self.ns["asyncio"] = SimpleNamespace(sleep=sleep)
        self.bus.restart_fail = True
        task = self.ns["maintain"](self.bus, self.iface)
        try:
            self.assertEqual(task.send(None), ("sleep", 10))
            self.bus.restart_fail = False
            self.assertEqual(task.send(None), ("sleep", 30))
            self.assertEqual(self.bus.restart_calls, 2)
            self.assertFalse(self.iface.refresh_pending)
        finally:
            task.close()

    def test_success_and_adaptive_defaults(self):
        self.assertTrue(self.apply(persist=1))
        self.assertTrue(self.iface.persist)
        self.assertEqual(self.saved[0]["controllers"]["Fan0 Control"]["OutLimitMax"], 20.0)
        self.assertTrue(self.apply(mode=0, duty=0))
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMin"], 30.0)
        self.assertEqual(self.bus.config["/fan0"]["OutLimitMax"], 100.0)

    def test_forget_file_error_keeps_previous_persistence(self):
        self.iface.persist = True
        def fail_delete():
            raise OSError("injected file removal failure")
        self.ns["delete_state"] = fail_delete
        self.assertFalse(complete(self.iface.ForgetSettings()))
        self.assertTrue(self.iface.persist)

    def test_invalid_request_does_not_write(self):
        self.assertFalse(self.apply(fan=6))
        self.assertFalse(self.apply(duty=9))
        self.assertEqual(self.bus.set_calls, 0)

    def test_dbus_helper_bounds_wait(self):
        # Use the real call() from a fresh module; only its transport/wait is fake.
        ns = load_service("ceb-gnrd-fan-settings.py")
        limits = []
        async def bounded_wait(coro, timeout):
            limits.append(timeout)
            return await coro
        ns["asyncio"] = SimpleNamespace(wait_for=bounded_wait)
        class Bus:
            async def call(self, message):
                return SimpleNamespace(message_type="ok", body=[True])
        self.assertEqual(complete(ns["call"](Bus(), "service", "/path", "interface", "Get")), [True])
        self.assertEqual(limits, [5])


class TemperatureFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_service("ceb-gnrd-temp-max.py")
        self.now = 100.0
        self.ns["time"] = SimpleNamespace(monotonic=lambda: self.now)
        self.ns["asyncio"] = SimpleNamespace(sleep=sleep)
        self.pings = []
        self.ns["sd_notify"] = self.pings.append
        self.sensors = {g: self.ns["TempSensor"](g) for g in ("CPU", "DIMM")}
        self.available = {g: self.ns["Availability"]() for g in self.sensors}
        self.functional = {g: self.ns["OperationalStatus"]() for g in self.sensors}
        self.progress = {"last_sample": self.now}
        self.task = self.ns["watchdog_task"](self.sensors, self.available, self.functional, self.progress)

    def tearDown(self):
        self.task.close()

    def step(self):
        self.assertEqual(self.task.send(None), ("sleep", 5))

    def test_stalled_sampling_stops_ping_and_protects_low_value(self):
        for sensor in self.sensors.values():
            sensor.update(40.0)
        self.step()
        self.now += 16
        self.step()
        for group in self.sensors:
            self.assertEqual(self.sensors[group].value, 70.0)
            self.assertTrue(self.available[group].state)
            self.assertFalse(self.functional[group].state)
        self.assertEqual(self.pings, ["WATCHDOG=1"])
        self.now += 60
        self.step()
        self.assertEqual(len(self.pings), 1)

    def test_protection_keeps_hot_reading_and_covers_nan(self):
        self.sensors["CPU"].update(96.0)
        self.now += 16
        self.step()
        self.assertEqual(self.sensors["CPU"].value, 96.0)
        self.assertEqual(self.sensors["DIMM"].value, 70.0)

    def test_sampling_recovery_resumes_ping(self):
        self.now += 16
        self.step()
        self.assertFalse(self.pings)
        self.progress["last_sample"] = self.now
        self.step()
        self.assertEqual(self.pings, ["WATCHDOG=1"])

    def test_unchanged_fresh_sampling_keeps_watchdog_healthy(self):
        for _ in range(20):
            self.now += 5
            self.progress["last_sample"] = self.now
            self.step()
        self.assertEqual(len(self.pings), 20)

    def test_main_stall_cannot_keep_watchdog_alive(self):
        tasks = []
        ns = self.ns
        class Bus:
            def __init__(self): self.exports = {}
            async def connect(self): return self
            def export(self, path, obj): self.exports.setdefault(path, []).append(obj)
            def add_message_handler(self, fn): pass
            async def request_name(self, name): pass
        bus = Bus()
        async def to_thread(fn, *args): return fn(*args)
        ns["MessageBus"] = lambda **kw: bus
        ns["asyncio"] = SimpleNamespace(to_thread=to_thread, sleep=sleep,
                                         create_task=tasks.append)
        ns["scan_sources"] = lambda: {"cpu": ("CPU", "Die"), "dimm": ("DIMM", "DIMM0")}
        ns["peci_cpu_present"] = lambda: True
        ns["rescan_peci"] = lambda: None
        ns["read_values"] = lambda paths: {"cpu": 40.0, "dimm": 40.0}
        async def no_assoc(*args): return []
        ns["find_board_assoc"] = no_assoc
        ns["find_default_assoc"] = no_assoc
        calls = 0
        async def host_on(bus):
            nonlocal calls
            calls += 1
            if calls > 1:
                await Pause("stalled-host-query")
            return True
        ns["host_is_on"] = host_on
        main = ns["main"]()
        try:
            self.assertEqual(main.send(None), ("sleep", 2))
            self.assertEqual(main.send(None), "stalled-host-query")
            self.now += 16
            self.assertEqual(tasks[0].send(None), ("sleep", 5))
            cpu = next(o for o in bus.exports[ns["SENSOR_ROOT"] + "/CPU_MAX_TEMP"]
                       if isinstance(o, ns["TempSensor"]))
            self.assertEqual(cpu.value, 70.0)
            self.assertNotIn("WATCHDOG=1", self.pings)
        finally:
            main.close()
            for task in tasks: task.close()


if __name__ == "__main__":
    unittest.main()
