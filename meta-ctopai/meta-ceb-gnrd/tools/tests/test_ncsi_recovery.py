#!/usr/bin/env python3
"""Run the real NC-SI shell policy with fake D-Bus, addresses and monotonic time.

No physical interface or system service is accessed. A POSIX shell and awk are
required; NCSI_TEST_SHELL can select a shell when it is not on PATH.
"""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


BOARD = Path(__file__).resolve().parents[2]
SCRIPT = BOARD / "recipes-phosphor/network/files/manage-ncsi-link.sh"
V4 = "3: eth1 inet 192.168.185.203/24 scope global eth1"
V6 = "3: eth1 inet6 2001:db8::203/64 scope global dynamic"


def shell_path(path):
    value = Path(path).resolve().as_posix()
    if os.name == "nt":
        value = "/" + value[0].lower() + value[2:]
    return shlex.quote(value)


def find_shell():
    shell = os.environ.get("NCSI_TEST_SHELL") or shutil.which("sh")
    if not shell and os.name == "nt":
        candidate = Path.home() / (
            ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/usr/bin/dash.exe"
        )
        if candidate.is_file():
            shell = str(candidate)
    return shell


class NcsiRecovery(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shell = find_shell()
        if not cls.shell:
            raise unittest.SkipTest("POSIX shell unavailable")

    def run_policy(self, phase="echo ready", address="return 0", dhcp="echo 'b true'",
                   carrier="return 0", down="return 0", limit=240):
        with tempfile.TemporaryDirectory(prefix="ncsi-policy-") as directory:
            root = Path(directory)
            (root / "eth1").mkdir()
            (root / "up").write_text("1\n", newline="\n")
            (root / "actions").write_text("")
            prelude = f"""
test_root={shell_path(root)}
test_now=1
test_phase() {{ {phase}; }}
test_address() {{ {address}; }}
test_dhcp() {{ {dhcp}; }}
test_carrier() {{ {carrier}; }}
test_down() {{ {down}; }}
busctl() {{
    phase=$(test_phase)
    case "$*" in
        *CurrentPowerState)
            case "$phase" in
                unknown) return 1 ;;
                off) echo 's "xyz.openbmc_project.State.Chassis.PowerState.Off"' ;;
                *) echo 's "xyz.openbmc_project.State.Chassis.PowerState.On"' ;;
            esac ;;
        *OperatingSystemState)
            if [ "$phase" = post ]; then
                echo 's "xyz.openbmc_project.State.OperatingSystem.Status.OSStatus.Inactive"'
            else
                echo 's "xyz.openbmc_project.State.OperatingSystem.Status.OSStatus.Standby"'
            fi ;;
        *NICEnabled)
            if [ "$phase" = disabled ]; then echo 'b false'; else echo 'b true'; fi ;;
        *DHCP4) test_dhcp ;;
        *) return 1 ;;
    esac
}}
link_is_up() {{ read -r test_up < "$test_root/up"; [ "$test_up" = 1 ]; }}
has_carrier() {{ link_is_up && test_carrier; }}
monotonic_seconds() {{ echo "$test_now"; }}
ip() {{
    if [ "$1" = -o ]; then test_address; return $?; fi
    [ "$1" = link ] || return 1
    printf 'ACTION %s %s\\n' "$test_now" "$5" >> "$test_root/actions"
    if [ "$5" = down ]; then
        test_down || return 1
        echo 0 > "$test_root/up"
    else
        echo 1 > "$test_root/up"
    fi
}}
logger() {{ printf 'LOG %s\\n' "$*"; }}
sleep() {{
    # Coarse polling keeps Windows shell startup overhead bounded; the
    # down/up guard still advances exactly one second to test its race.
    if link_is_up; then test_now=$((test_now + 5)); else test_now=$((test_now + 1)); fi
    if [ "$test_now" -ge {limit} ]; then cat "$test_root/actions"; exit 0; fi
}}
"""
            source = SCRIPT.read_text().replace(
                '"/sys/class/net/$IFACE"', '"$test_root/eth1"'
            )
            source = source.replace("last_gate=initial", prelude + "\nlast_gate=initial", 1)
            script = root / "policy.sh"
            script.write_text(source, newline="\n")
            env = os.environ.copy()
            env["PATH"] = str(Path(self.shell).parent) + os.pathsep + env.get("PATH", "")
            result = subprocess.run(
                [self.shell, "-c", ". " + shell_path(script)],
                env=env, capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            actions = [(int(t), action) for t, action in
                       re.findall(r"^ACTION (\d+) (down|up)$", result.stdout, re.M)]
            return actions, result.stdout

    def test_stalled_dhcp_restarts_link_at_most_three_times(self):
        actions, output = self.run_policy()
        self.assertEqual([a for _, a in actions], ["down", "up"] * 3)
        self.assertGreaterEqual(actions[0][0], 61)
        self.assertIn("recovery limit reached", output)

    def test_address_arriving_after_first_reset_stops_recovery(self):
        actions, _ = self.run_policy(address=f"[ $test_now -lt 80 ] || echo '{V4}'")
        self.assertEqual([a for _, a in actions], ["down", "up"])

    def test_healthy_startup_disarms_even_if_address_is_lost_later(self):
        actions, _ = self.run_policy(
            address=f"if [ $test_now -ge 20 ] && [ $test_now -lt 100 ]; then echo '{V4}'; fi"
        )
        self.assertEqual(actions, [])

    def test_static_mode_without_address_is_not_reset(self):
        actions, _ = self.run_policy(dhcp="echo 'b false'")
        self.assertEqual(actions, [])

    def test_failed_dhcp_query_is_not_reset(self):
        actions, _ = self.run_policy(dhcp="return 1")
        self.assertEqual(actions, [])

    def test_failed_address_query_is_not_reset(self):
        actions, _ = self.run_policy(address="return 2")
        self.assertEqual(actions, [])

    def test_working_ipv6_does_not_get_bounced_for_missing_ipv4(self):
        actions, _ = self.run_policy(address=f"echo '{V6}'")
        self.assertEqual(actions, [])

    def test_link_local_ipv4_does_not_disarm_recovery(self):
        actions, _ = self.run_policy(address="echo '3: eth1 inet 169.254.85.117/16 scope global eth1'")
        self.assertEqual([a for _, a in actions], ["down", "up"] * 3)

    def test_tentative_ipv6_does_not_disarm_recovery(self):
        actions, _ = self.run_policy(address=f"echo '{V6} tentative'")
        self.assertEqual([a for _, a in actions], ["down", "up"] * 3)

    def test_unknown_gate_restarts_grace_period_without_reprobing(self):
        actions, _ = self.run_policy(
            phase="if [ $test_now -ge 40 ] && [ $test_now -lt 100 ]; then echo unknown; else echo ready; fi"
        )
        self.assertGreaterEqual(actions[0][0], 160)

    def test_cable_loss_preserves_discovered_channel_and_restarts_grace(self):
        actions, _ = self.run_policy(
            carrier="[ $test_now -lt 40 ] || [ $test_now -ge 100 ]"
        )
        self.assertGreaterEqual(actions[0][0], 160)

    def test_host_shutdown_during_down_does_not_raise_interface(self):
        actions, _ = self.run_policy(
            phase="if [ $test_now -ge 62 ]; then echo off; else echo ready; fi", limit=120
        )
        self.assertEqual([a for _, a in actions], ["down"])

    def test_admin_disable_during_down_does_not_raise_interface(self):
        actions, _ = self.run_policy(
            phase="if [ $test_now -ge 62 ]; then echo disabled; else echo ready; fi", limit=120
        )
        self.assertEqual([a for _, a in actions], ["down"])

    def test_failed_down_is_bounded_and_spaced(self):
        actions, _ = self.run_policy(down="return 1")
        self.assertEqual([a for _, a in actions], ["down"] * 3)
        self.assertTrue(all(b[0] - a[0] >= 60 for a, b in zip(actions, actions[1:])))

    def test_new_host_power_cycle_rearms_startup_recovery(self):
        actions, _ = self.run_policy(
            phase="if [ $test_now -ge 40 ] && [ $test_now -lt 80 ]; then echo off; else echo ready; fi",
            address=f"if [ $test_now -lt 40 ]; then echo '{V4}'; fi",
            limit=210,
        )
        downs = [t for t, action in actions if action == "down"]
        self.assertEqual(len(downs), 2)
        self.assertLess(downs[0], 80)  # Actual host shutdown.
        self.assertGreaterEqual(downs[1], 140)  # New startup DHCP grace elapsed.

    def test_dhcp_disabled_during_down_still_restores_enabled_interface(self):
        actions, _ = self.run_policy(
            dhcp="if [ $test_now -ge 62 ]; then echo 'b false'; else echo 'b true'; fi"
        )
        self.assertEqual([a for _, a in actions], ["down", "up"])


class NetworkMigration(unittest.TestCase):
    def test_online_policy_migration_preserves_settings_and_is_idempotent(self):
        shell = find_shell()
        if not shell:
            self.skipTest("POSIX shell unavailable")
        fixtures = [
            ("00-bmc-eth1.network", "[Link]\nActivationPolicy=manual\nRequiredForOnline=no\n", "routable"),
            ("00-bmc-eth1.network", "[Link]\nActivationPolicy=down\nRequiredForOnline=yes\n", "no"),
            ("10-bmc-eth1-ncsi.network", "[Link]\nActivationPolicy=always-down\n", "no"),
            ("00-bmc-eth1.network", "", "routable"),
            ("00-bmc-eth0.network", "", None),
        ]
        source = (BOARD / "recipes-core/systemd/files/ceb-gnrd-clear-network-mac.sh").read_text()
        for name, link, required in fixtures:
            with self.subTest(name=name, link=link), tempfile.TemporaryDirectory(prefix="ncsi-migration-") as directory:
                root = Path(directory)
                network = root / "network"
                network.mkdir()
                config = network / name
                config.write_text(
                    "[Match]\nName=eth1\n" + link +
                    "[Network]\nDHCP=ipv4\nAddress=192.0.2.10/24\nDNS=192.0.2.1\nNTP=time.example\n"
                    "[Neighbor]\nMACAddress=02:11:22:33:44:55\n",
                    newline="\n",
                )
                # Only redirect filesystem locations; execute the real migration.
                posix_root = root.resolve().as_posix()
                if os.name == "nt":
                    posix_root = "/" + posix_root[0].lower() + posix_root[2:]
                script = root / "migration.sh"
                script.write_text(source.replace("/etc/systemd/network", posix_root + "/network")
                                  .replace("/run/ceb-gnrd-network-migration.", posix_root + "/migration."),
                                  newline="\n")
                env = os.environ.copy()
                env["PATH"] = str(Path(shell).parent) + os.pathsep + env.get("PATH", "")
                def run():
                    result = subprocess.run([shell, "-c", ". " + shell_path(script)], env=env,
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                run()
                migrated = config.read_bytes()
                modified = config.stat().st_mtime_ns
                text = migrated.decode()
                self.assertIn("Address=192.0.2.10/24", text)
                self.assertIn("DNS=192.0.2.1", text)
                self.assertIn("NTP=time.example", text)
                self.assertIn("[Neighbor]\nMACAddress=02:11:22:33:44:55", text)
                if required:
                    self.assertEqual(text.count("RequiredForOnline="), 1)
                    self.assertIn("RequiredForOnline=" + required, text)
                    if required == "no":
                        self.assertIn(link.splitlines()[1], text)
                else:
                    self.assertNotIn("RequiredForOnline=", text)
                run()
                self.assertEqual(config.read_bytes(), migrated)
                self.assertEqual(config.stat().st_mtime_ns, modified)


if __name__ == "__main__":
    unittest.main()
