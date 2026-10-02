#!/bin/sh
# CEB-GNRD functional check + log collection.  Run it ON THE BMC (QEMU or board):
#
#   sh /tmp/ceb-gnrd-check.sh            # prints PASS / FAIL per item, writes the files below
#
# Output:
#   /tmp/ceb-gnrd-check/report.txt       full command output of every check
#   /tmp/ceb-gnrd-check/*.log            journal, dmesg, units, D-Bus trees ...
#   /tmp/ceb-gnrd-check.tar.gz           all of the above in one file
#
# The expected values are the ones for the QEMU ast2600-evb run (no fans, no
# PECI, no host, no RTC).  Items that only make sense on the real board are marked
# "info" and never fail.  Everything runs with BusyBox sh.

PW=${BMC_PASSWORD:-0penBmc}
DIR=/tmp/ceb-gnrd-check
rm -rf "$DIR"; mkdir -p "$DIR"
REPORT=$DIR/report.txt
: > "$REPORT"
PASS=0; FAIL=0

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { printf '\n===== %s =====\n' "$*" | tee -a "$REPORT"; }

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

sec "1. System and services"
check "image version is 2.0.0" "grep -E '^VERSION_ID' /etc/os-release" '2\.0\.0'
check "no unexpected failed units (obmc-read-eeprom is expected without the FRU EEPROM)" \
      "systemctl --failed --no-legend | grep -v obmc-read-eeprom | wc -l" '^ *0$'
check "BMC state is Ready" \
      "busctl get-property xyz.openbmc_project.State.BMC /xyz/openbmc_project/state/bmc0 xyz.openbmc_project.State.BMC CurrentBMCState" 'Ready'
for u in bmcweb phosphor-ipmi-host phosphor-ipmi-net@eth0 xyz.openbmc_project.EntityManager \
         phosphor-pid-control ceb-gnrd-fan-settings ceb-gnrd-temp-max ceb-gnrd-alert-led \
         ceb-gnrd-rtc-sync xyz.openbmc_project.Dump.Manager xyz.openbmc_project.Logging.IPMI \
         dropbear.socket sshd.socket; do
    if systemctl cat "$u" >/dev/null 2>&1; then
        check "unit $u is active" "systemctl is-active $u" '^(active|listening)$'
    fi
done
check "SSH port 22 listening" "ss -ltn | grep -E ':22 '" ':22'
check "HTTPS port 443 listening" "ss -ltn | grep -E ':443 '" ':443'

sec "2. Sensors (ipmitool sensor)"
check "at least 18 sensors" "ipmitool sensor | wc -l" '^ *(1[89]|[2-9][0-9]|[1-9][0-9][0-9])$'
check "CPU_MAX_TEMP and DIMM_MAX_TEMP present" "ipmitool sensor | grep -c -E 'CPU_MAX_TEMP|DIMM_MAX_TEMP'" '^ *2$'
check "voltage sensor shows upper critical" "ipmitool sensor get P12V_SYS" 'Upper Critical'
check "CPU_MAX_TEMP upper non-recoverable 105 (needs ipmid patch 0002)" \
      "ipmitool sensor get CPU_MAX_TEMP" 'Upper Non-Recoverable *: *105'
check "DIMM_MAX_TEMP upper non-recoverable 95" \
      "ipmitool sensor get DIMM_MAX_TEMP" 'Upper Non-Recoverable *: *95'
info  "full sensor list" "ipmitool sensor"

sec "3. IPMI general"
check "manufacturer ID 0x1A03 = 6659" "ipmitool mc info" 'Manufacturer ID *: *6659'
check "firmware revision 2.00" "ipmitool mc info" 'Firmware Revision *: *2\.00'
check "chassis status answers" "ipmitool chassis status" 'System Power'
check "SEL answers" "ipmitool sel info" 'Version'
check "SEL rollover/overflow policy visible" "ipmitool sel info" '(Overflow|Supported Cmds)'
info  "SEL entries (last 20)" "ipmitool sel list | tail -n 20"
info  "FRU" "ipmitool fru print"
info  "LAN channel 1" "ipmitool lan print 1"
info  "users" "ipmitool user list 1"
info  "DCMI (not supported by design)" "ipmitool dcmi power reading"

sec "4. Fan control (OEM commands, pid-control)"
check "pid-control has no stepwise error" "journalctl -b --no-pager | grep -c 'Must have one stepwise'" '^ *0$'
check "pid-control built the zone and curves" "journalctl -b --no-pager | grep -E 'PID name:'" 'max_temperature_fan_curve'
check "OEM get returns 25 bytes" "ipmitool raw 0x30 0x01 | wc -w" '^ *25$'
check "OEM set all fans fixed 60 %, no keep" "ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x00; echo rc=\$?" 'rc=0'
check "OEM read-back shows mode 01 duty 3c" "ipmitool raw 0x30 0x01" '01 3c'
check "OEM set fan 2 adaptive" "ipmitool raw 0x30 0x02 0x02 0x00 0x00 0x00; echo rc=\$?" 'rc=0'
check "OEM read-back fan 2 is mode 00 and fan 1 still 01" \
      "ipmitool raw 0x30 0x01 | tr -s ' \n' ' ' | cut -d' ' -f2-25" '^ ?01 3c [0-9a-f]{2} [0-9a-f]{2} 01 3c [0-9a-f]{2} [0-9a-f]{2} 00 '
check "OEM keep flag set to 1" "ipmitool raw 0x30 0x02 0xFF 0x01 0x28 0x01; ipmitool raw 0x30 0x01 | tr -s ' \n' ' ' | cut -d' ' -f2" '^ ?01$'
check "kept settings file written" "cat /var/lib/ceb-gnrd/fan-settings.json" '"persist": true'
check "OEM keep flag cleared and file removed" \
      "ipmitool raw 0x30 0x02 0xFF 0x00 0x00 0x00; ls /var/lib/ceb-gnrd/fan-settings.json 2>&1" 'No such file'
check "OEM rejects an invalid fan" "ipmitool raw 0x30 0x02 0x09 0x00 0x00 0x00 2>&1" 'Invalid data field'
check "Pid objects are named Fan<n> Control" \
      "busctl tree xyz.openbmc_project.EntityManager --list | grep -c -E 'Fan[0-5]_Control'" '^ *6$'
info  "fan tach / PWM objects" "busctl tree xyz.openbmc_project.fansensor --list; ls /xyz 2>/dev/null; ls /sys/class/hwmon"
info  "fan-settings journal" "journalctl -u ceb-gnrd-fan-settings -b --no-pager | tail -n 20"

sec "5. Redfish / web"
check "Redfish root" "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/" 'RedfishVersion'
check "Manager firmware version" "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Managers/bmc" 'FirmwareVersion'
check "BMC dump collection answers" \
      "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Managers/bmc/LogServices/Dump/Entries" 'Members'
check "event log answers" \
      "curl -sk -u root:$PW https://127.0.0.1/redfish/v1/Systems/system/LogServices/EventLog/Entries" 'Members'
check "fan-settings D-Bus method reachable through bmcweb" \
      "curl -sk -u root:$PW -X POST -H 'Content-Type: application/json' -d '{\"data\":[]}' https://127.0.0.1/xyz/openbmc_project/ceb_gnrd/fan_settings/action/GetFans" '"status": *"ok"'
check "web UI is served" "curl -sk https://127.0.0.1/ | head -c 300" '(html|HTML)'

sec "6. Time, RTC, flash layout"
check "RTC sync unit ran" "systemctl is-active ceb-gnrd-rtc-sync" 'active'
info  "time and RTC (no /dev/rtc0 in QEMU)" "date; ls -l /dev/rtc0; hwclock -r"
check "MTD partitions u-boot/kernel/rofs/rwfs" "cat /proc/mtd" 'rwfs'
check "rwfs is mounted and persistent" "df -h /var/lib | tail -n 1" 'cow|overlay|ubi|mtd'
info  "u-boot environment" "fw_printenv bootcmd bootargs ipaddr serverip"

sec "7. Other BMC functions"
check "alert LED sysfs exists" "ls /sys/class/leds/" 'alert|system|identify|bmc'
check "obmc-console (SOL) unit exists" "systemctl list-units --all --no-legend 'obmc-console*' | wc -l" '^ *[1-9]'
info  "network" "ip -br addr"
info  "NC-SI (expected: no channel in QEMU)" "dmesg | grep -i ncsi | tail -n 5"
info  "LEDs" "ls /sys/class/leds; busctl tree xyz.openbmc_project.LED.GroupManager --list"
info  "host / chassis state (no host in QEMU)" "obmcutil state 2>&1"

sec "8. Errors in this boot (review these by hand)"
info  "journal errors (priority err and worse)" "journalctl -b -p err --no-pager | tail -n 60"
info  "kernel warnings" "dmesg | grep -i -E 'fail|error|warn' | tail -n 40"

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
tar czf /tmp/ceb-gnrd-check.tar.gz -C /tmp ceb-gnrd-check 2>/dev/null

sec "Summary"
say "PASS=$PASS  FAIL=$FAIL"
say "report : $REPORT"
say "bundle : /tmp/ceb-gnrd-check.tar.gz"
say "copy it out of QEMU with:  scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz ."
[ "$FAIL" -eq 0 ]
