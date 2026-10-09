#!/bin/sh
# Instantiate the CRPS PMBus devices only for the PSU modules that are
# actually installed.  The chassis may hold 0, 1 or 2 modules at 0x58/0x59/0x5a
# on I2C8 (Linux i2c-7); declaring all three in the device tree would make the
# kernel log a probe failure for every empty address at each boot.
#
# Modules are hot-pluggable, so the bus is polled and devices are added or
# removed as modules appear or disappear.  Only state changes are logged.
# psusensor only looks for PMBus hwmon devices when it starts, so it is
# restarted after every change: the sensors of a new module then appear on
# D-Bus (Redfish, IPMI, web) and those of a pulled module go away.

BUS=7
ADDRS="0x58 0x59 0x5a"
DRIVER=megcrps800
POLL_SECONDS=10
# A module is only removed after this many polls in a row without an answer
# (one failed transfer, e.g. while the module is busy, must not drop it).
MISS_LIMIT=2
SYSFS=/sys/bus/i2c/devices/i2c-$BUS

log() {
    echo "$*"
    logger -t ceb-gnrd-psu "$*" 2>/dev/null || true
}

# Use the driver's locked telemetry path once bound; never force raw I2C
# transfers past its PAGE/PEC handling. Before binding, STATUS_WORD (0x79)
# is documented by MEG-CRPS800AOP; STATUS_BYTE is not in its command table.
is_present() {
    device=$(dev_dir "$1")
    if [ -e "$device/driver" ]; then
        for input in "$device"/hwmon/hwmon*/in1_input; do
            [ -r "$input" ] || continue
            cat "$input" >/dev/null 2>&1
            return $?
        done
        return 1
    fi
    i2cget -y "$BUS" "$1" 0x79 w >/dev/null 2>&1
}

# Bus address in the form used by the kernel device directory, e.g. 7-0058.
dev_dir() {
    printf '/sys/bus/i2c/devices/%s-%04x' "$BUS" "$1"
}

add_device() {
    addr=$1
    if echo "$DRIVER" "$addr" > "$SYSFS/new_device" 2>/dev/null; then
        sleep 1
        if [ -e "$(dev_dir "$addr")/driver" ]; then
            log "PSU at $addr detected, $DRIVER driver bound"
        else
            log "WARNING: PSU at $addr answers on I2C but $DRIVER did not bind; check model/probe errors"
        fi
    else
        log "WARNING: PSU at $addr detected but the device could not be created"
    fi
}

remove_device() {
    addr=$1
    echo "$addr" > "$SYSFS/delete_device" 2>/dev/null || true
    log "PSU at $addr removed"
}

log "PSU presence monitor started on i2c-$BUS ($ADDRS)"
while :
do
    changed=0
    for addr in $ADDRS
    do
        if [ -e "$(dev_dir "$addr")" ]; then
            have=1
        else
            have=0
        fi
        miss=$(cat "/tmp/ceb-gnrd-psu-miss$addr" 2>/dev/null || echo 0)
        if is_present "$addr"; then
            echo 0 > "/tmp/ceb-gnrd-psu-miss$addr"
            # Migrate clients left by an older firmware; only this monitor
            # owns MEGCRPS800 devices, psusensor never creates/deletes them.
            if [ "$have" -eq 1 ] &&
               [ "$(cat "$(dev_dir "$addr")/name" 2>/dev/null)" != "$DRIVER" ]; then
                remove_device "$addr"
                have=0
            fi
            if [ "$have" -eq 0 ]; then
                add_device "$addr"
                echo 0 > "/tmp/ceb-gnrd-psu-retry$addr"
                changed=1
            elif [ ! -e "$(dev_dir "$addr")/driver" ]; then
                # Reprobe a failed client once a minute, not every callback.
                retry=$(cat "/tmp/ceb-gnrd-psu-retry$addr" 2>/dev/null || echo 0)
                retry=$((retry + 1))
                if [ "$retry" -ge 6 ]; then
                    retry=0
                    device_id=$(printf '%s-%04x' "$BUS" "$addr")
                    if echo "$device_id" > "/sys/bus/i2c/drivers/$DRIVER/bind" 2>/dev/null; then
                        log "PSU at $addr driver rebound"
                        changed=1
                    else
                        log "WARNING: PSU at $addr $DRIVER retry failed"
                    fi
                fi
                echo "$retry" > "/tmp/ceb-gnrd-psu-retry$addr"
            else
                echo 0 > "/tmp/ceb-gnrd-psu-retry$addr"
            fi
        elif [ "$have" -eq 1 ]; then
            miss=$((miss + 1))
            echo "$miss" > "/tmp/ceb-gnrd-psu-miss$addr"
            if [ "$miss" -ge "$MISS_LIMIT" ]; then
                echo 0 > "/tmp/ceb-gnrd-psu-miss$addr"
                remove_device "$addr"
                changed=1
            fi
        fi
    done
    if [ "$changed" -eq 1 ]; then
        systemctl restart xyz.openbmc_project.psusensor.service 2>/dev/null ||
            log "WARNING: could not restart psusensor"
    fi
    sleep "$POLL_SECONDS"
done
