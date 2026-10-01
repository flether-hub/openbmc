#!/bin/sh
# Instantiate the CRPS PMBus devices only for the PSU modules that are
# actually installed.  The chassis may hold 0, 1 or 2 modules at 0x58/0x59/0x5a
# on I2C8 (Linux i2c-7); declaring all three in the device tree would make the
# kernel log a probe failure for every empty address at each boot.
#
# Modules are hot-pluggable, so the bus is polled and devices are added or
# removed as modules appear or disappear.  Only state changes are logged.

BUS=7
ADDRS="0x58 0x59 0x5a"
POLL_SECONDS=5
SYSFS=/sys/bus/i2c/devices/i2c-$BUS

log() {
    echo "$*"
    logger -t ceb-gnrd-psu "$*" 2>/dev/null || true
}

# STATUS_BYTE (0x78) is mandatory in PMBus, so a present module always answers.
is_present() {
    i2cget -y "$BUS" "$1" 0x78 b >/dev/null 2>&1
}

# Bus address in the form used by the kernel device directory, e.g. 7-0058.
dev_dir() {
    printf '/sys/bus/i2c/devices/%s-%04x' "$BUS" "$1"
}

add_device() {
    addr=$1
    if echo pmbus "$addr" > "$SYSFS/new_device" 2>/dev/null; then
        sleep 1
        if [ -e "$(dev_dir "$addr")/driver" ]; then
            log "PSU at $addr detected, pmbus driver bound"
        else
            log "WARNING: PSU at $addr answers on I2C but the pmbus driver did not bind"
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
    for addr in $ADDRS
    do
        if [ -e "$(dev_dir "$addr")" ]; then
            have=1
        else
            have=0
        fi
        if is_present "$addr"; then
            [ "$have" -eq 0 ] && add_device "$addr"
        else
            [ "$have" -eq 1 ] && remove_device "$addr"
        fi
    done
    sleep "$POLL_SECONDS"
done