#!/bin/sh
# CEB-GNRD functional check + log collection.  Run it ON THE BMC:
#
#   ceb-gnrd-check 0                     # virtual machine (QEMU)
#   ceb-gnrd-check 1                     # physical board
#   ceb-gnrd-check                       # no argument: same as 0 (virtual machine)
#   (prints PASS / FAIL per item and writes the files below)
#   CEB_CHECK_NO_FAN_WRITE=1 ceb-gnrd-check   # do not change fan settings (section 4)
#   CEB_CHECK_KILL=1         ceb-gnrd-check   # also kill ceb-gnrd-temp-max and see it restart
#                                              # (this test rebooted the BMC once: off by default)
#   CEB_CHECK_CLEAR_LOGS=1   ceb-gnrd-check   # also run the destructive Redfish ClearLog
#                                              # test on the board (QEMU always runs it)
#
# The script detects whether it runs in QEMU (ast2600-evb) or on the real board and
# checks each item against what that environment should show:
#   board  : the hardware is there, so fans, PECI, RTC, eSPI, KCS, POST code, VUART,
#            intrusion sensor ... must work.  Items that also need the host powered on
#            are checked only while the chassis is On, otherwise they are "skip".
#   qemu   : no fans, PECI, board RTC chip or host.  The board checks are *rehearsed*
#            here ([try ]): the command runs, a wrong value is expected, but a shell
#            error inside it counts as FAIL, so script bugs show up before the board run.  The SoC blocks (eSPI registers,
#            KCS, LPC snoop, VUART, intrusion latch) exist there too, so the software
#            chain around them is checked; the hardware-dependent items are "skip".
#   both   : software that runs the same everywhere (services, IPMI, Redfish, web,
#            OEM fan commands, SEL / Redfish log chain, restart policy ...).
#
# Output:
#   /tmp/ceb-gnrd-check/report.txt       full command output of every check
#   /tmp/ceb-gnrd-check/*.log            journal, dmesg, units, D-Bus trees ...
#   /tmp/ceb-gnrd-check.tar.gz           all of the above in one file
#
# The QEMU expectations come from real QEMU runs.  The board expectations have not
# been run on a board yet: a FAIL there is a lead to look at, not a verdict.
# When anything fails, the failed commands with their output and the relevant logs
# are printed again at the very end, so the console text alone is enough to report it.
# Everything runs with BusyBox sh.

PW=${BMC_PASSWORD:-0penBmc}
DIR=/tmp/ceb-gnrd-check
rm -rf "$DIR"; mkdir -p "$DIR"
REPORT=$DIR/report.txt
: > "$REPORT"
PASS=0; FAIL=0; SKIP=0; TRYOK=0; TRYNO=0
FAILS=$DIR/fails.txt
: > "$FAILS"

MARK=/var/lib/ceb-gnrd/check-running.txt
mkdir -p /var/lib/ceb-gnrd 2>/dev/null
# mark "name": remember which item is running, in persistent storage (/tmp is lost
# at a reboot), so that a BMC reboot in the middle of a test shows on the next run
# which item was running.
mark() { printf '%s\n' "$1" > "$MARK" 2>/dev/null; sync; }

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { printf '\n===== %s =====\n' "$*" | tee -a "$REPORT"; }

# ---- environment detection ----
detect_env() {
    case "$1" in
        0) ENV=qemu;  WHY="argument 0"; return ;;
        1) ENV=board; WHY="argument 1"; return ;;
    esac
    if [ -n "$CEB_ENV" ]; then ENV=$CEB_ENV; WHY="CEB_ENV override"; return; fi
    ENV=qemu; WHY="no argument: the default is the virtual machine, use 1 for the board"
}
detect_env "$1"
if [ -s "$MARK" ]; then
    say "NOTE: the previous run did not finish (the BMC may have rebooted). It was running: $(cat "$MARK")"
fi
say "environment: $ENV ($WHY)"

host_on() {
    busctl get-property xyz.openbmc_project.State.Chassis /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis CurrentPowerState 2>/dev/null | grep -q 'PowerState.On'
}
if host_on; then HOST=on; else HOST=off; fi
say "host chassis power: $HOST"

# run "command": every command gets a time limit so one hung tool cannot block the run
run() {
    if command -v timeout >/dev/null 2>&1; then timeout 40 sh -c "$1"; else sh -c "$1"; fi
}

# diag_cmds "name of the failed check": the commands that usually explain that failure,
# one per line.  They are run when the check fails and their output goes into the FAIL
# details at the end, so no log has to be collected by hand.
diag_cmds() {
    case "$1" in
    "unit "*" is active")
        u=${1#unit }; u=${u% is active}
        printf '%s\n' "systemctl status $u --no-pager -n 20" "journalctl -u $u -b --no-pager -n 25" ;;
    *"failed units"*)
        printf '%s\n' "systemctl --failed --no-pager" \
            "for u in \$(systemctl --failed --no-legend | awk '{print \$2}'); do echo == \$u; journalctl -u \$u -b --no-pager -n 12; done" ;;
    *"IPMI over LAN"*|*"IPMI SOL"*|*"UDP 623"*)
        printf '%s\n' "busctl tree xyz.openbmc_project.Settings --list | grep -i -E 'sol|ipmi'" \
            "journalctl -b --no-pager | grep -i 'Sol Config' | tail -n 5" "ip -br addr""grep -i -E ':026F ' /proc/net/udp /proc/net/udp6" \
            "systemctl status phosphor-ipmi-net@eth0 --no-pager -n 15" \
            "journalctl -u phosphor-ipmi-net@eth0 -b --no-pager -n 20" \
            "ipmitool user list 1" "ipmitool channel getaccess 1 1" \
            "ipmitool -I lanplus -H 127.0.0.1 -U root -P $PW -vvv mc info 2>&1 | tail -n 20" ;;
    *"IPMI"*|*"SEL"*|*"rsyslog"*|*"event log"*|*"Redfish event"*|*"ClearLog"*|*"REDFISH_MESSAGE_ID"*)
        printf '%s\n' "systemctl status rsyslog --no-pager -n 15" "journalctl -u rsyslog -b --no-pager -n 20" \
            "ls -l /var/log/ipmi_sel* /var/log/redfish* /etc/rsyslog.d" \
            "journalctl -u xyz.openbmc_project.Logging.IPMI -b --no-pager -n 20" \
            "journalctl -u phosphor-ipmi-host -b --no-pager -n 20" "ipmitool sel info" ;;
    *"Redfish"*|*"bmcweb"*|*"web UI"*|*"fan-settings D-Bus"*)
        printf '%s\n' "systemctl status bmcweb --no-pager -n 15" "journalctl -u bmcweb -b --no-pager -n 25" \
            "curl -sk -i -u root:$PW https://127.0.0.1/redfish/v1/ | head -n 15" ;;
    *"OEM"*|*"pid"*|*"Pid"*|*"fan"*|*"Fan"*)
        printf '%s\n' "journalctl -u phosphor-pid-control -b --no-pager -n 25" \
            "journalctl -u ceb-gnrd-fan-settings -b --no-pager -n 25" \
            "busctl tree xyz.openbmc_project.EntityManager --list | grep -i -E 'fan|pid'" \
            "ls /sys/class/hwmon; cat /sys/class/hwmon/*/name" ;;
    *"sensor"*|*"voltage"*|*"CPU_MAX"*|*"DIMM_MAX"*|*"STBY"*|*"NonRecoverable"*|*"ADC"*)
        printf '%s\n' "ipmitool sensor | head -n 40" "journalctl -u ceb-gnrd-temp-max -b --no-pager -n 20" \
            "journalctl -u xyz.openbmc_project.EntityManager -b --no-pager -n 20" \
            "busctl tree xyz.openbmc_project.ADCSensor --list | head -n 30" ;;
    *"intrusion"*|*"Intrusion"*|*"PhysicalSecurity"*)
        printf '%s\n' "ls -l /sys/class/hwmon/*/intrusion0_alarm" "cat /sys/class/hwmon/*/intrusion0_alarm" \
            "journalctl -u xyz.openbmc_project.intrusionsensor -b --no-pager -n 20" \
            "busctl tree xyz.openbmc_project.IntrusionSensor --list" ;;
    *"RTC"*|*"rtc"*)
        printf '%s\n' "ls -l /dev/rtc*" "dmesg | grep -i rtc | tail -n 15" "journalctl -u ceb-gnrd-rtc-sync -b --no-pager -n 20" \
            "i2cdetect -y 9" ;;
    *"VUART"*|*"ttyVUART0"*|*"obmc-console"*|*"SOL"*)
        printf '%s\n' "ls -l /dev/ttyVUART0 /dev/ttyS*" "cat /proc/tty/driver/serial" \
            "systemctl status obmc-console@ttyVUART0 --no-pager -n 15" \
            "journalctl -u obmc-console@ttyVUART0 -b --no-pager -n 20" \
            "dmesg | grep -i -E 'vuart|ttyS5|serial' | tail -n 15" \
            "udevadm info -q property -n /dev/ttyS5 2>&1 | head -n 15" ;;
    *"eSPI"*|*"ESPI"*|*"Virtual Wire"*)
        printf '%s\n' "dmesg | grep -i espi | tail -n 25" \
            "for r in 0x1e6ee000 0x1e6ee004 0x1e6ee098 0x1e6ee0a0 0x1e6ee0a4; do echo \$r: \$(devmem \$r 32 2>&1); done" \
            "for f in \$(find /sys/kernel/debug -name regs 2>/dev/null | grep -i espi); do echo \$f; cat \$f; done" ;;
    *"KCS"*|*"snoop"*|*"POST code"*|*"POST complete"*)
        printf '%s\n' "ls -l /dev/ipmi-kcs* /dev/aspeed-lpc-snoop*" "dmesg | grep -i -E 'kcs|snoop' | tail -n 15" \
            "journalctl -u phosphor-ipmi-kcs@ipmi-kcs3 -b --no-pager -n 15" \
            "busctl tree xyz.openbmc_project.State.Boot.PostCode0 --list" \
            "busctl list --no-legend | grep -i -E 'postcode|State.Boot|OperatingSystem'" ;;
    *"LED"*|*"heartbeat"*)
        printf '%s\n' "ls /sys/class/leds" "cat /sys/class/leds/bmc-heartbeat/trigger" \
            "busctl tree xyz.openbmc_project.LED.GroupManager --list" \
            "journalctl -u phosphor-led-manager -b --no-pager -n 15" \
            "journalctl -u ceb-gnrd-alert-led -b --no-pager -n 20" ;;
    *"watchdog"*|*"quiesce"*|*"OnFailure"*|*"restart"*)
        printf '%s\n' "systemctl show -p RuntimeWatchdogUSec -p WatchdogDevice" "ls -l /dev/watchdog*" \
            "dmesg | grep -i -E 'wdt|watchdog' | tail -n 10" \
            "systemctl show bmcweb ceb-gnrd-temp-max -p Restart -p OnFailure -p StartLimitBurst" ;;
    *"MTD"*|*"flash"*|*"rwfs"*)
        printf '%s\n' "cat /proc/mtd" "df -h" "mount | grep -E 'rwfs|overlay|mtd'" ;;
    *"network"*|*"eth0"*)
        printf '%s\n' "ip -br addr" "ip -br link" "dmesg | grep -i -E 'ftgmac|ncsi|eth0' | tail -n 15" ;;
    esac
}

# note_fail "name" "command" "output" "why": keep the details for the FAIL block at the
# end, followed by the output of the diagnostic commands that belong to this check
note_fail() {
    {
        printf '### %s\n' "$1"
        printf '$ %s\n' "$2"
        [ -n "$4" ] && printf '(%s)\n' "$4"
        printf '%s\n' "$3" | head -n 40 | cut -c1-220
        d=$(diag_cmds "$1")
        if [ -n "$d" ]; then
            printf -- '--- diagnostics ---\n'
            printf '%s\n' "$d" | while IFS= read -r c; do
                [ -n "$c" ] || continue
                printf '$ %s\n' "$c"
                run "$c" 2>&1 | head -n 25 | cut -c1-200
            done
        fi
        printf '\n'
    } >> "$FAILS"
}

# check "name" "command" "extended regex the output must match"
check() {
    mark "$1  [$2]"
    out=$(run "$2" 2>&1)
    printf '\n$ %s\n%s\n' "$2" "$out" >> "$REPORT"
    if printf '%s\n' "$out" | grep -Eq "$3"; then
        PASS=$((PASS+1)); say "[PASS] $1"
    else
        FAIL=$((FAIL+1))
        say "[FAIL] $1   expected /$3/"
        say "       got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        note_fail "$1" "$2" "$out" "expected /$3/"
    fi
}

# info "name" "command"   -- only recorded, never fails
info() {
    mark "$1  [$2]"
    printf '\n$ %s\n' "$2" >> "$REPORT"
    run "$2" >> "$REPORT" 2>&1
    say "[info] $1"
}

skip() { SKIP=$((SKIP+1)); say "[skip] $1   ($2)"; }

# Shell mistakes in a command (not a wrong value): these are bugs of this script.
SHELL_ERR="(sh: .*(not found|syntax error|unexpected|bad number|Illegal option)|command not found|syntax error|bad number|arithmetic syntax|unknown operand|bad substitution|applet not found|unterminated)"

# rehearse "name" "command" "regex"   -- a board check run in QEMU.  The value usually
# cannot match without the hardware (not counted), but the command itself must run:
# a shell error here would also break the board run, so that one is a FAIL.
rehearse() {
    mark "$1  [$2]"
    out=$(run "$2" 2>&1)
    printf '\n$ %s\n%s\n' "$2" "$out" >> "$REPORT"
    if printf '%s\n' "$out" | grep -Eq "$SHELL_ERR"; then
        FAIL=$((FAIL+1)); say "[FAIL] $1   (script error while rehearsing a board check)"
        say "       got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        note_fail "$1" "$2" "$out" "script error while rehearsing a board check"
    elif printf '%s\n' "$out" | grep -Eq "$3"; then
        TRYOK=$((TRYOK+1)); say "[try ] $1   (command runs, value matches)"
    else
        TRYNO=$((TRYNO+1)); say "[try ] $1   (command runs, value needs the real hardware)"
    fi
}

# board "name" "command" "regex"      -- checked on the board; rehearsed in QEMU
board() {
    if [ "$ENV" = board ]; then check "$1" "$2" "$3"; else rehearse "$1" "$2" "$3"; fi
}
# board_on "name" "command" "regex"   -- board with the host chassis On; rehearsed in QEMU
board_on() {
    if [ "$ENV" != board ]; then rehearse "$1" "$2" "$3"
    elif [ "$HOST" != on ]; then skip "$1" "needs the host powered on"
    else check "$1" "$2" "$3"; fi
}
# qemu "name" "command" "regex"       -- checked in qemu only (the absent state)
qemu() {
    if [ "$ENV" = qemu ]; then check "$1" "$2" "$3"; else skip "$1" "qemu only"; fi
}
# env_info "name" "command"           -- recorded on both, never fails
env_info() { info "$1" "$2"; }

sec "1. System and services"
check "image version is 2.0.0" "grep -E '^VERSION_ID' /etc/os-release" '2\.0\.0'
if [ "$ENV" = board ]; then
    check "no failed units" "systemctl --failed --no-legend | wc -l" '^ *0$'
else
    check "no unexpected failed units (obmc-read-eeprom is expected without the FRU EEPROM)" \
          "systemctl --failed --no-legend | grep -v obmc-read-eeprom | wc -l" '^ *0$'
fi
check "device tree is the CEB-GNRD one" "tr -d '\000' < /proc/device-tree/model" 'CEB-GNRD'
check "BMC state is Ready" \
      "busctl get-property xyz.openbmc_project.State.BMC /xyz/openbmc_project/state/bmc0 xyz.openbmc_project.State.BMC CurrentBMCState" 'Ready'
for u in bmcweb phosphor-ipmi-host phosphor-ipmi-net@eth0 xyz.openbmc_project.EntityManager \
         phosphor-pid-control ceb-gnrd-fan-settings ceb-gnrd-temp-max ceb-gnrd-alert-led \
         ceb-gnrd-rtc-sync xyz.openbmc_project.Dump.Manager xyz.openbmc_project.Logging.IPMI \
         rsyslog phosphor-led-manager xyz.openbmc_project.LED.GroupManager \
         dropbear.socket sshd.socket; do
    if systemctl cat "$u" >/dev/null 2>&1; then
        check "unit $u is active" "systemctl is-active $u" '^(active|listening)$'
    fi
done
check "SSH port 22 listening" "grep -E ':0016 [0-9A-F:]+ 0A' /proc/net/tcp /proc/net/tcp6" ':0016'
check "HTTPS port 443 listening" "grep -E ':01BB [0-9A-F:]+ 0A' /proc/net/tcp /proc/net/tcp6" ':01BB'
check "x86-power-control owns the host / chassis / OS state and button names" \
      "busctl list --no-legend | grep -c -E 'xyz.openbmc_project.(State.Host|State.Chassis|State.OperatingSystem|Chassis.Buttons)( |$)'" '^ *[4-9]$'
check "button definitions installed (gpio_defs.json)" "ls /etc/default/obmc/gpio/gpio_defs.json >/dev/null 2>&1 && echo found" '^found$'
check "hardware watchdog armed by systemd (RuntimeWatchdogSec=120s)" \
      "systemctl show -p RuntimeWatchdogUSec" '(2min|120000000)'
check "watchdog device exists" "ls /dev/watchdog* >/dev/null 2>&1 && echo found" '^found$'
check "critical services restart then quiesce (StartLimit + OnFailure drop-in)" \
      "systemctl show bmcweb -p OnFailure -p Restart" 'quiesce'
check "own services restart only, no OnFailure (a single crash must not reboot the BMC)" \
      "systemctl show ceb-gnrd-temp-max ceb-gnrd-fan-settings ceb-gnrd-alert-led -p OnFailure -p Restart" 'Restart=always'
check "own services have an empty OnFailure=" \
      "systemctl show ceb-gnrd-temp-max ceb-gnrd-fan-settings ceb-gnrd-alert-led -p OnFailure | grep -c 'OnFailure=.'" '^ *0$'
check "BMC reboot after quiesce is limited (ExecCondition drop-in)" \
      "systemctl show phosphor-bmc-quiesce-reboot.service -p ExecCondition" 'reboot-limit'
if [ -z "$CEB_CHECK_KILL" ]; then
    skip "a killed service is restarted by systemd" "it rebooted the BMC once; set CEB_CHECK_KILL=1 to run it"
else
    check "a killed service is restarted by systemd (Restart=always on ceb-gnrd-temp-max)" \
          "systemctl kill -s KILL ceb-gnrd-temp-max; sleep 8; systemctl is-active ceb-gnrd-temp-max" '^active$'
fi
check "BMC local debug console is ttyS4 (UART5)" \
      "cat /proc/cmdline" 'ttyS4'

sec "2. Sensors (ipmitool sensor)"
if [ "$ENV" = board ]; then
    check "at least 25 sensors on the board" "ipmitool sensor | wc -l" '^ *(2[5-9]|[3-9][0-9]|[1-9][0-9][0-9])$'
else
    check "at least 18 sensors" "ipmitool sensor | wc -l" '^ *(1[89]|[2-9][0-9]|[1-9][0-9][0-9])$'
fi
check "no duplicate i2c client registration (-16) in dmesg (a device declared in the DT and in Entity-Manager)" \
      "dmesg | grep -c 'Failed to register i2c client.*(-16)'" '^ *0$'
board "four board temperature sensors exist (EnvTemp_Inlet/Outlet, BoardTemp_PCIe/M2)" \
      "ipmitool sensor | grep -c -E 'EnvTemp_Inlet|EnvTemp_Outlet|BoardTemp_PCIe|BoardTemp_M2'" '^ *4$'
check "CPU_MAX_TEMP and DIMM_MAX_TEMP present" "ipmitool sensor | grep -c -E 'CPU_MAX_TEMP|DIMM_MAX_TEMP'" '^ *2$'
# P12V_SYS and the other *_SYS rails are only read with the chassis on, so they are unavailable in QEMU.
check "STBY voltage sensor shows upper critical" "ipmitool sensor get P1V8_STBY" 'Upper Critical'
check "CPU_MAX_TEMP upper non-recoverable 105 (needs ipmid patch 0002)" \
      "ipmitool sensor get CPU_MAX_TEMP" 'Upper Non-Recoverable *: *105'
check "DIMM_MAX_TEMP upper non-recoverable 95" \
      "ipmitool sensor get DIMM_MAX_TEMP" 'Upper Non-Recoverable *: *95'
board    "STBY voltage reads a real value (not na)" "ipmitool sensor get P1V8_STBY" 'Sensor Reading *: *[0-9]'
board_on "SYS rail voltage reads a real value with the chassis on" "ipmitool sensor get P12V_SYS" 'Sensor Reading *: *[0-9]'
board_on "CPU_MAX_TEMP reads a real value (PECI) with the chassis on" "ipmitool sensor get CPU_MAX_TEMP" 'Sensor Reading *: *[0-9]'
board_on "DIMM_MAX_TEMP reads a real value (PECI) with the chassis on" "ipmitool sensor get DIMM_MAX_TEMP" 'Sensor Reading *: *[0-9]'
board    "six fan tach sensors exist" "ipmitool sensor | grep -c -i -E 'fan'" '^ *([6-9]|[1-9][0-9])$'
board_on "PECI CPU is on the PECI bus" "ls /sys/bus/peci/devices" 'peci'
check    "ADC IIO device exists" "ls /sys/bus/iio/devices" 'iio:device'
env_info "full sensor list" "ipmitool sensor"

sec "3. IPMI general"
check "manufacturer ID 0x1A03 = 6659" "ipmitool mc info" 'Manufacturer ID *: *6659'
check "firmware revision 2.00" "ipmitool mc info" 'Firmware Revision *: *2\.00'
check "chassis status answers" "ipmitool chassis status" 'System Power'
check "SEL answers" "ipmitool sel info" 'Version'
check "SEL rollover/overflow policy visible" "ipmitool sel info" '(Overflow|Supported Cmds)'
check "SEL logrotate timer is active" "systemctl is-active ceb-gnrd-sel-logrotate.timer" '^active$'
check "rsyslog reload works (ExecReload drop-in for Delete all in the web Event logs)" \
      "systemctl show rsyslog -p ExecReload" 'kill'
check "Redfish event log rule installed" "ls /etc/rsyslog.d/" 'ceb-gnrd-redfish.conf'
check "IPMI Get Device ID (raw)" "ipmitool raw 0x06 0x01" '^ *[0-9a-f]{2} '
# phosphor-ipmi-net is bound to eth0, so 127.0.0.1 is not answered: use the address of
# eth0.  If the default cipher suite is refused, cipher suite 3 is tried.
ETH0IP="ip=\$(ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n 1); echo ip=\$ip;"
IPMILAN="ipmitool -I lanplus -H \$ip -U root -P $PW"
check "phosphor-ipmi-net listens on UDP 623" "grep -i -E ':026F ' /proc/net/udp /proc/net/udp6" ':026F'
check "IPMI over LAN (RMCP+, phosphor-ipmi-net) answers" \
      "$ETH0IP $IPMILAN mc info || $IPMILAN -C 3 mc info" 'Manufacturer ID *: *6659'
check "IPMI SOL settings object exists on D-Bus (/xyz/openbmc_project/ipmi/sol/eth0)" \
      "busctl tree xyz.openbmc_project.Settings --list | grep -i /ipmi/sol" 'ipmi/sol/eth0'
check "IPMI SOL is configured over LAN" \
      "$ETH0IP $IPMILAN sol info 1 || $IPMILAN -C 3 sol info 1" 'Enabled'
check "chassis power restore policy is readable" "ipmitool chassis policy list" 'always-off|always-on|previous|no-change'
check "SEL add through phosphor-sel-logger shows up in ipmitool sel list" \
      "b=\$(ipmitool sel elist | wc -l); busctl call xyz.openbmc_project.Logging.IPMI /xyz/openbmc_project/Logging/IPMI xyz.openbmc_project.Logging.IPMI IpmiSelAdd ssaybq 'ceb-gnrd-check test event' /xyz/openbmc_project/sensors/temperature/CPU_MAX_TEMP 3 0x00 0xFF 0xFF true 0x0020 >/dev/null; sleep 4; a=\$(ipmitool sel elist | wc -l); echo before=\$b after=\$a; [ \$a -gt \$b ] && echo grew" '^grew$'
check "a journal entry with REDFISH_MESSAGE_ID reaches /var/log/redfish (rsyslog imjournal + rule)" \
      "b=\$(cat /var/log/redfish 2>/dev/null | wc -l); python3 -c \"import socket;s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM);s.sendto(b'MESSAGE=ceb-gnrd-check test\\nREDFISH_MESSAGE_ID=OpenBMC.0.1.SELEntryAdded\\nREDFISH_MESSAGE_ARGS=ceb-gnrd-check test\\n',  '/run/systemd/journal/socket')\"; sleep 4; a=\$(cat /var/log/redfish 2>/dev/null | wc -l); echo before=\$b after=\$a; [ \$a -gt \$b ] && echo grew" '^grew$'
if [ "$ENV" = qemu ] || [ -n "$CEB_CHECK_CLEAR_LOGS" ]; then
    # Deletes the Redfish event log: only in QEMU, or on the board with CEB_CHECK_CLEAR_LOGS=1.
    check "Redfish ClearLog works (the web Delete all button)" \
          "curl -sk -o /dev/null -w '%{http_code}' -u root:$PW -X POST -H 'Content-Type: application/json' -d '{}' https://127.0.0.1/redfish/v1/Systems/system/LogServices/EventLog/Actions/LogService.ClearLog" '^20[0-9]$'
else
    skip "Redfish ClearLog works" "it deletes the event log; set CEB_CHECK_CLEAR_LOGS=1 to run it on the board"
fi
env_info "SEL entries (last 20)" "ipmitool sel list | tail -n 20"
env_info "FRU" "ipmitool fru print"
env_info "LAN channel 1" "ipmitool lan print 1"
env_info "users" "ipmitool user list 1"
env_info "DCMI (not supported by design)" "ipmitool dcmi power reading"

sec "4. Fan control (OEM commands, pid-control)"
check "pid-control has no stepwise error" "journalctl -b --no-pager | grep -c 'Must have one stepwise'" '^ *0$'
check "pid-control built the zone and curves" "journalctl -b --no-pager | grep -E 'PID name:'" 'max_temperature_fan_curve'
check "OEM get returns 25 bytes" "ipmitool raw 0x30 0x01 | wc -w" '^ *25$'
check "Pid objects are named Fan<n> Control" \
      "busctl tree xyz.openbmc_project.EntityManager --list | grep -c -E 'Fan[0-5]_Control'" '^ *6$'
if [ -n "$CEB_CHECK_NO_FAN_WRITE" ]; then
    skip "OEM fan set / keep / invalid-fan tests" "CEB_CHECK_NO_FAN_WRITE is set"
else
    # These change the fan settings for a few seconds; the last command leaves all
    # fans on adaptive control without the keep flag, which is the default.
    check "OEM set all fans fixed 60 %, no keep" "ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x00; echo rc=\$?" 'rc=0'
    check "OEM read-back shows mode 01 duty 3c" "ipmitool raw 0x30 0x01" '01 3c'
    check "OEM set fan 2 adaptive" "ipmitool raw 0x30 0x02 0x02 0x00 0x00 0x00; echo rc=\$?" 'rc=0'
    check "OEM read-back fan 2 is mode 00 and fan 1 still 01" \
          "ipmitool raw 0x30 0x01 | tr -s ' \n' ' '" '^ ?[0-9a-f]{2} 01 3c [0-9a-f]{2} [0-9a-f]{2} 01 3c [0-9a-f]{2} [0-9a-f]{2} 00 '
    check "OEM keep flag set to 1" "ipmitool raw 0x30 0x02 0xFF 0x01 0x28 0x01; ipmitool raw 0x30 0x01 | tr -s ' \n' ' ' | cut -d' ' -f2" '^ ?01$'
    check "kept settings file written" "cat /var/lib/ceb-gnrd/fan-settings.json" '"persist": true'
    check "OEM keep flag cleared and file removed" \
          "ipmitool raw 0x30 0x02 0xFF 0x00 0x00 0x00; ls /var/lib/ceb-gnrd/fan-settings.json 2>&1" 'No such file'
    check "OEM rejects an invalid fan" "ipmitool raw 0x30 0x02 0x09 0x00 0x00 0x00 2>&1" 'Invalid data field'
fi
check "PWM/TACH hwmon device exists" "ls /sys/class/hwmon/*/name | xargs cat" 'pwm|tach|g6'
check "CPU and DIMM max temp sensors carry the NonRecoverable threshold interface (ceb-gnrd-temp-max)" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias /xyz/openbmc_project/sensors 0 1 com.ctopai.CebGnrd.Threshold.NonRecoverable" 'CPU_MAX_TEMP.*DIMM_MAX_TEMP|DIMM_MAX_TEMP.*CPU_MAX_TEMP'
env_info "BMC software version objects" "busctl tree xyz.openbmc_project.Software.BMC.Updater --list; busctl tree xyz.openbmc_project.Software.Version --list; busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias /xyz/openbmc_project/software 0 1 xyz.openbmc_project.Software.Version"
env_info "fan tach / PWM objects" "busctl tree xyz.openbmc_project.fansensor --list; ls /xyz 2>/dev/null; ls /sys/class/hwmon"
env_info "fan-settings journal" "journalctl -u ceb-gnrd-fan-settings -b --no-pager | tail -n 20"

sec "5. Redfish / web"
check "Redfish root" "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/" 'RedfishVersion'
check "Manager reports the BMC firmware version (empty here means the BMC version object is missing)" "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Managers/bmc | grep FirmwareVersion" 'FirmwareVersion"?: *"[^"]+'
check "BMC dump collection answers" \
      "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Managers/bmc/LogServices/Dump/Entries" 'Members'
check "event log answers" \
      "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Systems/system/LogServices/EventLog/Entries" 'Members'
check "Chassis resource answers" "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Chassis" 'Members'
check "fan-settings D-Bus method reachable through bmcweb" \
      "curl -sk -u root:$PW -X POST -H 'Content-Type: application/json' -d '{\"data\":[]}' https://127.0.0.1/xyz/openbmc_project/ceb_gnrd/fan_settings/action/GetFans" '"status": *"ok"'
for p in Systems/system Managers/bmc AccountService SessionService UpdateService; do
    check "Redfish /redfish/v1/$p answers 200" \
          "curl -sk -o /dev/null -w '%{http_code}' -u root:$PW https://127.0.0.1/redfish/v1/$p" '^200$'
done
check "Redfish Chassis exposes PhysicalSecurity (intrusion sensor)" \
      "c=\$(curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Chassis | grep -o '/redfish/v1/Chassis/[^\"]*' | head -n 1); echo \$c; curl -sk -u root:$PW https://127.0.0.1\$c | grep -c PhysicalSecurity" '^[1-9]'
check "web UI is served" "curl -sk https://127.0.0.1/ | head -n 5" '(html|HTML)'

sec "6. Time, RTC, flash layout"
check "RTC sync unit ran" "systemctl is-active ceb-gnrd-rtc-sync" 'active'
board "RTC device /dev/rtc0 exists (battery-backed NCT3018Y)" "[ -e /dev/rtc0 ] && echo found" '^found$'
qemu  "no /dev/rtc0 in QEMU (the SoC RTC is disabled, the RTC chip is not emulated)" "[ ! -e /dev/rtc0 ] && echo absent" '^absent$'
board "RTC (NCT3018Y) can be read" "hwclock -r" '[0-9]'
env_info "time and RTC" "date; ls -l /dev/rtc0; hwclock -r"
check "MTD partitions u-boot/kernel/rofs/rwfs" "cat /proc/mtd" 'rwfs'
check "rwfs is mounted and persistent" "df -h /var/lib | tail -n 1" 'cow|overlay|ubi|mtd'
board "BMC flash is 64 MiB (W25Q512JV)" "cat /sys/class/mtd/mtd0/size" '67108864'
env_info "u-boot environment" "fw_printenv bootcmd bootargs ipaddr serverip"

sec "7. Other BMC functions"
check "fault and identify LEDs exist (sysfs)" "ls /sys/class/leds/" 'fault'
check "enclosure_fault LED group is on D-Bus" "busctl --system get-property xyz.openbmc_project.LED.GroupManager /xyz/openbmc_project/led/groups/enclosure_fault xyz.openbmc_project.Led.Group Asserted" '^b (true|false)$'
LEDG="xyz.openbmc_project.LED.GroupManager /xyz/openbmc_project/led/groups/enclosure_fault xyz.openbmc_project.Led.Group Asserted"
check "enclosure_fault LED group can be asserted" \
      "busctl --system set-property $LEDG b true; busctl --system get-property $LEDG" '^b true$'
check "enclosure_fault LED group can be cleared again" \
      "busctl --system set-property $LEDG b false; busctl --system get-property $LEDG" '^b false$'
check "network: eth0 exists" "ip -br link show eth0" 'eth0'
check "network: eth0 link is up with an IPv4 address" "ip -br addr show eth0" 'UP .*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
check "chassis intrusion service is running" "systemctl is-active xyz.openbmc_project.intrusionsensor" '^active$'
check "chassis intrusion hwmon attribute exists (CHASI# latch)" "ls /sys/class/hwmon/hwmon*/intrusion0_alarm >/dev/null 2>&1 && echo found" '^found$'
check "chassis intrusion D-Bus object exists" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias / 0 1 xyz.openbmc_project.Chassis.Intrusion" 'Intrusion'
check "BMC heartbeat LED is blinking (eSPI driver bound)" "cat /sys/class/leds/bmc-heartbeat/trigger" '\[heartbeat\]'
env_info "NC-SI" "dmesg | grep -i ncsi | tail -n 5"
env_info "LEDs" "ls /sys/class/leds; busctl tree xyz.openbmc_project.LED.GroupManager --list"
env_info "host / chassis state" "obmcutil state 2>&1"
env_info "I2C buses and devices" "ls /sys/bus/i2c/devices; i2cdetect -l 2>&1"
env_info "GPIO lines in use" "gpioinfo 2>&1 | grep -i -E 'used|BMC_' | head -n 60"

sec "8. Host interface: eSPI, KCS, POST code, VUART / SOL"
check "obmc-console (SOL) unit exists" "systemctl list-units --all --no-legend 'obmc-console*' | wc -l" '^ *[1-9]'
check "host VUART is ttyVUART0 (udev symlink, VUART1 0x1E787000)" "ls -l /dev/ttyVUART0" 'ttyVUART0 -> '
check "VUART tty can be configured (stty)" "stty -F /dev/ttyVUART0 -a" 'speed|baud'
check "obmc-console@ttyVUART0 is active" "systemctl is-active obmc-console@ttyVUART0" '^active$'
board "VUART host address is COM1 0x3F8 (QEMU does not model it and reads 0x0)" "cat /sys/devices/platform/ahb/ahb:apb/1e787000.serial/lpc_address" '0x0*3f8'
check "eSPI driver marked the Peripheral and Virtual Wire channels ready" "dmesg | grep -i espi" 'Virtual Wire channels SW_READY set'
check "VUART1 is a registered 8250 port at 0x1E787000" "cat /proc/tty/driver/serial" 'mmio:0x1E787000'
check "obmc-console server listens on its socket" "grep -a obmc-console /proc/net/unix" 'obmc-console'
board "VUART SerIRQ is IRQ4" "cat /sys/devices/platform/ahb/ahb:apb/1e787000.serial/sirq" '^ *4$'
# ESPI000 (0x1E6EE000): bit3 VW SW ready, bit1 Peripheral SW ready, bits 27:24 queue resets
# (active low, must be 1 = running), bits 2 / 0 channel ready (only once the host enabled
# the channel).  ESPI098: bit23 slave boot status, bit20 slave boot done.  Needs /dev/mem.
board "ESPI000: VW and Peripheral SW ready set, queues not held in reset" \
      "v=\$(devmem 0x1e6ee000 32); echo \$v; [ \$(( v & 0x0f00000a )) -eq \$(( 0x0f00000a )) ] && echo ok" '^ok$'
board "ESPI098: slave boot done and status set (the host waits for them)" \
      "v=\$(devmem 0x1e6ee098 32); echo \$v; [ \$(( v & 0x00900000 )) -eq \$(( 0x00900000 )) ] && echo ok" '^ok$'
board_on "ESPI000: VW and Peripheral channels report ready (host enabled them)" \
      "v=\$(devmem 0x1e6ee000 32); echo \$v; [ \$(( v & 5 )) -eq 5 ] && echo ok" '^ok$'
board_on "eSPI reset from the host was handled (driver restarted the channels)" \
      "dmesg | grep -c 'eSPI_RESET# deasserted'" '^ *[1-9]'
env_info "eSPI registers ESPI000 / 004 / 098 / 0A0 / 0A4 (devmem)" \
         "for r in 0x1e6ee000 0x1e6ee004 0x1e6ee098 0x1e6ee0a0 0x1e6ee0a4; do echo \$r: \$(devmem \$r 32 2>&1); done"
check "no eSPI Peripheral errors / aborts since boot" "dmesg | grep -c -E 'PERIF_(NP|PC)_(TX|RX)_(ERR|ABT)'" '^ *0$'
check "KCS3 device for host IPMI exists" "ls /dev/ipmi-kcs3 >/dev/null 2>&1 && echo found" '^found$'
check "LPC snoop device for port 0x80 exists" "ls /dev/aspeed-lpc-snoop0 >/dev/null 2>&1 && echo found" '^found$'
check "POST code object is on D-Bus" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias /xyz/openbmc_project/State/Boot 0 0" 'PostCode'
board_on "POST code of the current boot is not empty" \
      "busctl get-property xyz.openbmc_project.State.Boot.PostCode0 /xyz/openbmc_project/State/Boot/PostCode0 xyz.openbmc_project.State.Boot.PostCode CurrentBootCycleCount" 'u [1-9]'
board_on "BIOS has signalled POST complete (OperatingSystemState Standby)" \
      "busctl get-property xyz.openbmc_project.State.OperatingSystem /xyz/openbmc_project/state/host0 xyz.openbmc_project.State.OperatingSystem.Status OperatingSystemState" 'Standby'
env_info "eSPI / KCS / snoop / VUART kernel messages" "dmesg | grep -i -E 'espi|kcs|snoop|vuart|serial' | tail -n 40"
env_info "VUART sysfs" "ls /sys/devices/platform/ahb/ahb:apb/1e787000.serial 2>&1; cat /sys/devices/platform/ahb/ahb:apb/1e787000.serial/lpc_address /sys/devices/platform/ahb/ahb:apb/1e787000.serial/sirq 2>&1"
env_info "eSPI debugfs registers" "for f in \$(find /sys/kernel/debug -name regs 2>/dev/null | grep -i espi); do echo \$f; cat \$f; done"

sec "9. Errors in this boot (review these by hand)"
env_info "journal errors (priority err and worse)" "journalctl -b -p err --no-pager | tail -n 60"
env_info "kernel warnings" "dmesg | grep -i -E 'fail|error|warn' | tail -n 40"

# ---- raw logs for the bundle ----
journalctl -b --no-pager            > "$DIR/journal.log" 2>&1
dmesg                               > "$DIR/dmesg.log" 2>&1
systemctl list-units --all --no-pager > "$DIR/units.log" 2>&1
systemctl --failed --no-pager       > "$DIR/failed-units.log" 2>&1
busctl list --no-pager              > "$DIR/dbus-services.log" 2>&1
busctl tree xyz.openbmc_project.ObjectMapper --list --no-pager > "$DIR/mapper-tree.log" 2>&1
busctl tree xyz.openbmc_project.EntityManager --list --no-pager > "$DIR/entity-manager-tree.log" 2>&1
ipmitool sdr elist                  > "$DIR/sdr.log" 2>&1
ipmitool sel elist                  > "$DIR/sel.log" 2>&1
cat /etc/os-release /proc/mtd /proc/cmdline > "$DIR/system.log" 2>&1
mount                               >> "$DIR/system.log" 2>&1
df -h                               >> "$DIR/system.log" 2>&1
ls -l /var/lib/ceb-gnrd /var/lib/phosphor-settings-manager /var/configuration >> "$DIR/system.log" 2>&1
ls /dev                             > "$DIR/dev.log" 2>&1
cat /proc/interrupts                > "$DIR/interrupts.log" 2>&1
ls /sys/class/hwmon /sys/class/leds /sys/bus/i2c/devices > "$DIR/sysfs.log" 2>&1
tar czf /tmp/ceb-gnrd-check.tar.gz -C /tmp ceb-gnrd-check 2>/dev/null

sec "Summary"
say "environment: $ENV, host power: $HOST"
say "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$ENV" = qemu ]; then
    say "board checks rehearsed here: $TRYOK match, $TRYNO need the real hardware (only a shell error in them counts as FAIL)"
fi
say "report : $REPORT"
say "bundle : /tmp/ceb-gnrd-check.tar.gz"
if [ "$ENV" = qemu ]; then
    say "copy it out of QEMU with:  scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz ."
else
    say "copy it off the board with:  scp root@<bmc-ip>:/tmp/ceb-gnrd-check.tar.gz ."
fi
rm -f "$MARK"
if [ "$FAIL" -gt 0 ]; then
    # Everything below is printed on the console so it can be copied and pasted as it is.
    printf '\n===== FAIL details: copy from here to the end =====\n' | tee -a "$REPORT"
    {
        echo "env=$ENV ($WHY) host=$HOST kernel=$(uname -r) $(grep -E '^VERSION_ID' /etc/os-release)"
        echo "FAIL=$FAIL PASS=$PASS"
        echo
        cat "$FAILS"
        echo "### failed units"
        systemctl --failed --no-legend --no-pager 2>&1 | cut -c1-200
        echo
        echo "### journal errors this boot (last 30)"
        journalctl -b -p err --no-pager 2>&1 | tail -n 30 | cut -c1-220
        echo
        echo "### kernel messages about eSPI / VUART / KCS / snoop / failures (last 30)"
        dmesg 2>&1 | grep -i -E 'espi|vuart|kcs|snoop|fail|error|warn' | tail -n 30 | cut -c1-220
        echo "===== end of FAIL details ====="
    } | tee -a "$REPORT"
fi
[ "$FAIL" -eq 0 ]
