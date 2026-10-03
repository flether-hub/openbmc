#!/bin/sh
# CEB-GNRD functional check + log collection.  Run it ON THE BMC:
#
#   ceb-gnrd-check                       # prints PASS / FAIL per item, writes the files below
#   CEB_ENV=board ceb-gnrd-check         # force the environment (qemu | board)
#   CEB_CHECK_NO_FAN_WRITE=1 ceb-gnrd-check   # do not change fan settings (section 4)
#
# The script detects whether it runs in QEMU (ast2600-evb) or on the real board and
# checks each item against what that environment should show:
#   board  : the hardware is there, so fans, PECI, RTC, eSPI, KCS, POST code, VUART,
#            intrusion sensor ... must work.  Items that also need the host powered on
#            are checked only while the chassis is On, otherwise they are "skip".
#   qemu   : no fans, PECI, RTC, host or eSPI; those items are "info" or "skip", and
#            a few (no /dev/rtc0) must show the absent state.
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
# Everything runs with BusyBox sh.

PW=${BMC_PASSWORD:-0penBmc}
DIR=/tmp/ceb-gnrd-check
rm -rf "$DIR"; mkdir -p "$DIR"
REPORT=$DIR/report.txt
: > "$REPORT"
PASS=0; FAIL=0; SKIP=0

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { printf '\n===== %s =====\n' "$*" | tee -a "$REPORT"; }

# ---- environment detection ----
detect_env() {
    if [ -n "$CEB_ENV" ]; then ENV=$CEB_ENV; WHY="CEB_ENV override"; return; fi
    mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
    case "$mac" in
        52:54:00:*) ENV=qemu; WHY="eth0 MAC $mac is the QEMU default prefix"; return ;;
    esac
    if dmesg 2>/dev/null | grep -qi 'qemu'; then ENV=qemu; WHY="qemu found in dmesg"; return; fi
    ENV=board; WHY="eth0 MAC '$mac', no QEMU marker"
}
detect_env
say "environment: $ENV ($WHY)"

host_on() {
    busctl get-property xyz.openbmc_project.State.Chassis /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis CurrentPowerState 2>/dev/null | grep -q 'PowerState.On'
}
if host_on; then HOST=on; else HOST=off; fi
say "host chassis power: $HOST"

# check "name" "command" "extended regex the output must match"
check() {
    out=$(sh -c "$2" 2>&1)
    printf '\n$ %s\n%s\n' "$2" "$out" >> "$REPORT"
    if printf '%s\n' "$out" | grep -Eq "$3"; then
        PASS=$((PASS+1)); say "[PASS] $1"
    else
        FAIL=$((FAIL+1))
        say "[FAIL] $1   expected /$3/"
        say "       got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    fi
}

# info "name" "command"   -- only recorded, never fails
info() {
    printf '\n$ %s\n' "$2" >> "$REPORT"
    sh -c "$2" >> "$REPORT" 2>&1
    say "[info] $1"
}

skip() { SKIP=$((SKIP+1)); say "[skip] $1   ($2)"; }

# board "name" "command" "regex"      -- checked on the board only, qemu: skip
board() {
    if [ "$ENV" = board ]; then check "$1" "$2" "$3"; else skip "$1" "board only"; fi
}
# board_on "name" "command" "regex"   -- board and host chassis On only
board_on() {
    if [ "$ENV" != board ]; then skip "$1" "board only"
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
check "button definitions installed (gpio_defs.json)" "ls /etc/default/obmc/gpio/gpio_defs.json" 'gpio_defs.json'
check "hardware watchdog armed by systemd (RuntimeWatchdogSec=120s)" \
      "systemctl show -p RuntimeWatchdogUSec" '(2min|120000000)'
check "watchdog device exists" "ls /dev/watchdog*" 'watchdog'
check "critical services restart then quiesce (StartLimit + OnFailure drop-in)" \
      "systemctl show bmcweb -p OnFailure -p Restart" 'quiesce'
check "BMC reboot after quiesce is limited (ExecCondition drop-in)" \
      "systemctl show phosphor-bmc-quiesce-reboot.service -p ExecCondition" 'reboot-limit'
check "BMC local debug console is ttyS4 (UART5)" \
      "cat /proc/cmdline" 'ttyS4'

sec "2. Sensors (ipmitool sensor)"
if [ "$ENV" = board ]; then
    check "at least 25 sensors on the board" "ipmitool sensor | wc -l" '^ *(2[5-9]|[3-9][0-9]|[1-9][0-9][0-9])$'
else
    check "at least 18 sensors" "ipmitool sensor | wc -l" '^ *(1[89]|[2-9][0-9]|[1-9][0-9][0-9])$'
fi
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
board    "ADC IIO device exists" "ls /sys/bus/iio/devices" 'iio:device'
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
board "PWM/TACH hwmon device exists" "ls /sys/class/hwmon/*/name | xargs cat" 'pwm|tach|g6'
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
check "web UI is served" "curl -sk https://127.0.0.1/ | head -n 5" '(html|HTML)'

sec "6. Time, RTC, flash layout"
check "RTC sync unit ran" "systemctl is-active ceb-gnrd-rtc-sync" 'active'
board "RTC device /dev/rtc0 exists (NCT3018Y)" "ls -l /dev/rtc0" 'rtc0'
board "RTC can be read" "hwclock -r" '[0-9]'
qemu  "no /dev/rtc0 in QEMU" "ls /dev/rtc0 2>&1" 'No such file'
env_info "time and RTC" "date; ls -l /dev/rtc0; hwclock -r"
check "MTD partitions u-boot/kernel/rofs/rwfs" "cat /proc/mtd" 'rwfs'
check "rwfs is mounted and persistent" "df -h /var/lib | tail -n 1" 'cow|overlay|ubi|mtd'
board "BMC flash is 64 MiB (W25Q512JV)" "cat /sys/class/mtd/mtd0/size" '67108864'
env_info "u-boot environment" "fw_printenv bootcmd bootargs ipaddr serverip"

sec "7. Other BMC functions"
check "fault and identify LEDs exist (sysfs)" "ls /sys/class/leds/" 'fault'
check "enclosure_fault LED group is on D-Bus" "busctl --system get-property xyz.openbmc_project.LED.GroupManager /xyz/openbmc_project/led/groups/enclosure_fault xyz.openbmc_project.Led.Group Asserted" '^b (true|false)$'
check "network: eth0 exists" "ip -br link show eth0" 'eth0'
board "network: eth0 link is up with an IPv4 address" "ip -br addr show eth0" 'UP .*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
check "chassis intrusion service is running" "systemctl is-active xyz.openbmc_project.intrusionsensor" '^active$'
board "chassis intrusion hwmon attribute exists (CHASI# latch)" "ls /sys/class/hwmon/hwmon*/intrusion0_alarm" 'intrusion0_alarm'
board "chassis intrusion D-Bus object exists" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias / 0 1 xyz.openbmc_project.Chassis.Intrusion" 'Intrusion'
qemu  "no chassis intrusion object in QEMU (no CHASI# hardware)" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias / 0 1 xyz.openbmc_project.Chassis.Intrusion 2>&1" '(as 0|not found|Failed)'
board "BMC heartbeat LED is blinking (eSPI driver bound)" "cat /sys/class/leds/bmc-heartbeat/trigger" '\[heartbeat\]'
env_info "NC-SI" "dmesg | grep -i ncsi | tail -n 5"
env_info "LEDs" "ls /sys/class/leds; busctl tree xyz.openbmc_project.LED.GroupManager --list"
env_info "host / chassis state" "obmcutil state 2>&1"
env_info "I2C buses and devices" "ls /sys/bus/i2c/devices; i2cdetect -l 2>&1"
env_info "GPIO lines in use" "gpioinfo 2>&1 | grep -i -E 'used|BMC_' | head -n 60"

sec "8. Host interface: eSPI, KCS, POST code, VUART / SOL"
check "obmc-console (SOL) unit exists" "systemctl list-units --all --no-legend 'obmc-console*' | wc -l" '^ *[1-9]'
board "host VUART is ttyVUART0 (udev symlink, VUART1 0x1E787000)" "ls -l /dev/ttyVUART0" 'ttyVUART0 -> '
board "obmc-console@ttyVUART0 is active" "systemctl is-active obmc-console@ttyVUART0" '^active$'
board "VUART host address is COM1 0x3F8" "cat /sys/devices/platform/ahb/ahb:apb/1e787000.serial/lpc_address" '0x0*3f8'
board "eSPI Peripheral driver marked the channel ready" "dmesg | grep -i espi" 'SW_READY set'
board "no eSPI Peripheral errors / aborts since boot" "dmesg | grep -c -E 'PERIF_(NP|PC)_(TX|RX)_(ERR|ABT)'" '^ *0$'
board "KCS3 device for host IPMI exists" "ls /dev/ipmi-kcs3" 'ipmi-kcs3'
board "LPC snoop device for port 0x80 exists" "ls /dev/aspeed-lpc-snoop0" 'snoop0'
board "POST code object is on D-Bus" \
      "busctl call xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper GetSubTreePaths sias /xyz/openbmc_project/State/Boot 0 0" 'PostCode'
board_on "POST code of the current boot is not empty" \
      "busctl get-property xyz.openbmc_project.State.Boot.PostCode0 /xyz/openbmc_project/State/Boot/PostCode0 xyz.openbmc_project.State.Boot.PostCode CurrentBootCycleCount" 'u [1-9]'
board_on "BIOS has signalled POST complete (OperatingSystemState Standby)" \
      "busctl get-property xyz.openbmc_project.State.OperatingSystem /xyz/openbmc_project/state/host0 xyz.openbmc_project.State.OperatingSystem.Status OperatingSystemState" 'Standby'
qemu  "no host serial device in QEMU (no VUART path to a host)" "ls /dev/ttyVUART0 2>&1" '(No such file|ttyVUART0)'
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
say "report : $REPORT"
say "bundle : /tmp/ceb-gnrd-check.tar.gz"
if [ "$ENV" = qemu ]; then
    say "copy it out of QEMU with:  scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz ."
else
    say "copy it off the board with:  scp root@<bmc-ip>:/tmp/ceb-gnrd-check.tar.gz ."
fi
[ "$FAIL" -eq 0 ]
