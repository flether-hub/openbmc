#!/bin/sh
# Instantiate the CRPS PMBus devices only for the PSU modules that are
# actually installed.  The chassis may hold 0, 1 or 2 modules at 0x58/0x59/0x5a
# on I2C8 (Linux i2c-7); declaring all three in the device tree would make the
# kernel log a probe failure for every empty address at each boot.
#
# Detect the installed modules once during BMC startup, before psusensor.
# The PSU configuration stays fixed until the next BMC startup. This service
# owns the I2C clients; psusensor only consumes their hwmon telemetry.

BUS=7
ADDRS="0x58 0x59 0x5a"
SYSFS=/sys/bus/i2c/devices/i2c-$BUS

log() {
    echo "$*"
    logger -t ceb-gnrd-psu "$*" 2>/dev/null || true
}

# Use the driver's locked telemetry path once bound; never force raw I2C
# transfers past its PAGE/PEC handling. Generic PSUs need not expose VIN,
# so use any supported telemetry input. Before binding, try STATUS_WORD
# first, then STATUS_BYTE for PSUs which do not implement the word command.
is_present() {
    device=$(dev_dir "$1")
    if [ -e "$device/driver" ]; then
        for input in "$device"/hwmon/hwmon*/*_input; do
            [ -r "$input" ] || continue
            if cat "$input" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi
    i2cget -y "$BUS" "$1" 0x79 w >/dev/null 2>&1 ||
        i2cget -y "$BUS" "$1" 0x78 b >/dev/null 2>&1
}

# Bus address in the form used by the kernel device directory, e.g. 7-0058.
dev_dir() {
    printf '/sys/bus/i2c/devices/%s-%04x' "$BUS" "$1"
}

# MFR_MODEL is an SMBus block string, not a fixed-length I2C block. Bound
# clients expose it through PMBus debugfs, which holds the driver's lock.
# If debugfs is unavailable, keep the working driver until removal/reprobe.
read_model() {
    device=$(dev_dir "$1")
    if [ -e "$device/driver" ]; then
        for hwmon in "$device"/hwmon/hwmon*; do
            model_file="/sys/kernel/debug/pmbus/$(basename "$hwmon")/mfr_model"
            [ -r "$model_file" ] || continue
            raw=$(cat "$model_file" 2>/dev/null) || continue
            printf '%s' "$raw" | LC_ALL=C tr -cd '[:alnum:]' |
                LC_ALL=C tr '[:lower:]' '[:upper:]'
            return 0
        done
        return 1
    fi

    raw=$(i2cget -y "$BUS" "$1" 0x9a s 2>/dev/null) || return 1
    [ -n "$raw" ] || return 1
    # i2cget prints each payload byte as 0xNN (without a length prefix).
    for byte in $raw; do
        case "$byte" in
            0x[0-9a-fA-F][0-9a-fA-F]) ;;
            *) return 1 ;;
        esac
    done
    for byte in $raw; do
        code=$((byte))
        if { [ "$code" -ge 48 ] && [ "$code" -le 57 ]; } ||
           { [ "$code" -ge 65 ] && [ "$code" -le 90 ]; } ||
           { [ "$code" -ge 97 ] && [ "$code" -le 122 ]; }; then
            printf '%b' "\\0$(printf '%03o' "$code")"
        fi
    done | LC_ALL=C tr '[:lower:]' '[:upper:]'
}

select_driver() {
    case "$2" in
        MEGCRPS800AOP|CRPS800AOP) echo megcrps800 ;;
        "")
            bound=$(basename "$(readlink "$(dev_dir "$1")/driver" 2>/dev/null)")
            case "$bound" in
                megcrps800|pmbus) echo "$bound" ;;
                *) echo pmbus ;;
            esac
            ;;
        *) echo pmbus ;;
    esac
}

add_device() {
    addr=$1
    driver=$2
    if echo "$driver" "$addr" > "$SYSFS/new_device" 2>/dev/null; then
        sleep 1
        if [ -e "$(dev_dir "$addr")/driver" ]; then
            log "PSU at $addr detected, model=${model:-unknown}, $driver driver bound"
        else
            log "WARNING: PSU at $addr model=${model:-unknown} answers on I2C but $driver did not bind; check probe errors"
            return 1
        fi
    else
        log "WARNING: PSU at $addr detected but the device could not be created"
        return 1
    fi
    return 0
}

remove_device() {
    addr=$1
    if ! echo "$addr" > "$SYSFS/delete_device" 2>/dev/null; then
        log "WARNING: PSU at $addr could not be removed"
        return 1
    fi
    log "PSU at $addr removed"
}

# Allow the I2C adapter to appear during startup, with a bounded wait.
wait_count=0
while [ ! -e "$SYSFS/new_device" ]; do
    if [ "$wait_count" -ge 10 ]; then
        log "ERROR: PSU I2C adapter i2c-$BUS is unavailable"
        exit 1
    fi
    sleep 1
    wait_count=$((wait_count + 1))
done

log "PSU startup detection on i2c-$BUS ($ADDRS)"
result=0
for addr in $ADDRS; do
    have=0
    [ ! -e "$(dev_dir "$addr")" ] || have=1

    # Short startup retries avoid treating one busy transfer as an empty slot.
    attempt=0
    present=0
    while [ "$attempt" -lt 3 ]; do
        if is_present "$addr"; then
            present=1
            break
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -ge 3 ] || sleep 1
    done
    if [ "$present" -eq 0 ]; then
        if [ "$have" -eq 1 ]; then
            remove_device "$addr" || result=1
        fi
        continue
    fi

    model=$(read_model "$addr" || true)
    driver=$(select_driver "$addr" "$model")
    if [ "$have" -eq 1 ] &&
       [ "$(cat "$(dev_dir "$addr")/name" 2>/dev/null)" != "$driver" ]; then
        if ! remove_device "$addr"; then
            result=1
            continue
        fi
        have=0
    fi
    if [ "$have" -eq 0 ]; then
        add_device "$addr" "$driver" || result=1
    elif [ ! -e "$(dev_dir "$addr")/driver" ]; then
        device_id=$(printf '%s-%04x' "$BUS" "$addr")
        if echo "$device_id" > "/sys/bus/i2c/drivers/$driver/bind" 2>/dev/null; then
            log "PSU at $addr $driver driver rebound"
        else
            log "WARNING: PSU at $addr $driver bind failed"
            result=1
        fi
    else
        log "PSU at $addr model=${model:-unknown} already bound to $driver"
    fi
done
exit "$result"
