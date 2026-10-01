#!/bin/bash
# 通过 AST2600 SPI1 更新 BIOS NOR；BMC 启动 Flash 位于 Firmware SPI/FMC。
set -euo pipefail

readonly FLASH_SELECT_GPIO="BMC_BIOS_FLASH_SELECT"
readonly MTD_PARTITION_NAME="host-bios"
readonly EXPECTED_FLASH_SIZE=67108864
readonly HOST_SHUTDOWN_TIMEOUT_S=1800
readonly HOST_OFF_STABLE_S=3
readonly FORCE_OFF_PULSE_S=16
FLASH_SELECT_PID=""
FLASH_OWNERSHIP_SELECTED=0

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: $0 <directory-containing-BIOS-image>" >&2
    exit 2
fi

power_status() {
    local state
    state=$(busctl get-property xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis CurrentPowerState 2>/dev/null) || return 2
    case "$state" in
        *"PowerState.On"*)                    echo on ;;
        *"PowerState.Off"*)                   echo off ;;
        *"PowerState.TransitioningToOff"*|*"PowerState.TransitioningToOn"*)
            echo transitioning
            ;;
        *) return 2 ;;
    esac
}

wait_for_host_off() {
    local elapsed=0 stable=0 state
    state=$(power_status) || {
        echo "ERROR: Unable to determine host power state; BIOS update is blocked." >&2
        return 1
    }

    if [[ "$state" == on ]]; then
        local message="BIOS update is waiting for the user to shut down the host."
        echo "$message"
        logger -p user.warning -t bios-update "$message" || true
    fi

    while (( elapsed < HOST_SHUTDOWN_TIMEOUT_S )); do
        state=$(power_status) || {
            echo "ERROR: Unable to determine host power state; BIOS update is blocked." >&2
            return 1
        }

        if [[ "$state" == off ]]; then
            ((stable += 1))
            if (( stable >= HOST_OFF_STABLE_S )); then
                echo "Host is confirmed off and stable."
                return 0
            fi
        else
            stable=0
        fi

        if (( elapsed > 0 && elapsed % 30 == 0 )); then
            local message="BIOS update still waiting for host shutdown (${elapsed}s elapsed)."
            echo "$message"
            logger -p user.warning -t bios-update "$message" || true
        fi
        sleep 1
        ((elapsed += 1))
    done

    echo "ERROR: Host did not reach stable Off state within ${HOST_SHUTDOWN_TIMEOUT_S}s; BIOS was not modified." >&2
    logger -p user.err -t bios-update "Host shutdown timeout; BIOS was not modified." || true
    return 1
}

wait_for_host_off

IMAGE_FILE=$(find "$1" -type f \( -iname '*.fd' -o -iname '*.bin' \) -print -quit)
if [[ -z "$IMAGE_FILE" ]]; then
    echo "ERROR: BIOS image (.FD/.BIN) not found in $1" >&2
    exit 1
fi

find_bios_mtd() {
    local entry name size
    for entry in /sys/class/mtd/mtd[0-9]*; do
        [[ "$(basename "$entry")" =~ ^mtd[0-9]+$ ]] || continue
        [[ -r "$entry/name" && -r "$entry/size" ]] || continue
        IFS= read -r name < "$entry/name"
        if [[ "$name" == "$MTD_PARTITION_NAME" ]]; then
            IFS= read -r size < "$entry/size"
            if (( size != EXPECTED_FLASH_SIZE )); then
                echo "ERROR: $MTD_PARTITION_NAME has size $size, expected $EXPECTED_FLASH_SIZE bytes." >&2
                return 1
            fi
            printf '/dev/%s\n' "$(basename "$entry")"
            return 0
        fi
    done
    echo "ERROR: SPI1 MTD partition '$MTD_PARTITION_NAME' not found" >&2
    return 1
}

reprobe_bios_spi_nor() {
    local driver_dir=/sys/bus/spi/drivers/spi-nor
    local device
    [[ -w "$driver_dir/bind" ]] || return 0

    # The first probe can run before GPIOM1 switches the shared flash to BMC.
    # Rebind the matching, unbound SPI-NOR device after ownership is selected.
    for device in /sys/bus/spi/devices/spi*; do
        [[ -r "$device/of_node/compatible" ]] || continue
        grep -aq 'jedec,spi-nor' "$device/of_node/compatible" || continue
        [[ -e "$device/driver" ]] && continue
        printf '%s' "$(basename "$device")" > "$driver_dir/bind" 2>/dev/null || true
    done
}

set_flash_select() {
    local level=$1 gpiochip line
    if [[ -n "$FLASH_SELECT_PID" ]]; then
        kill "$FLASH_SELECT_PID" 2>/dev/null || true
        wait "$FLASH_SELECT_PID" 2>/dev/null || true
        FLASH_SELECT_PID=""
    fi
    read -r gpiochip line <<< "$(gpiofind "$FLASH_SELECT_GPIO")"
    if [[ -z "${gpiochip:-}" || -z "${line:-}" ]]; then
        echo "ERROR: GPIO line not found: $FLASH_SELECT_GPIO" >&2
        return 1
    fi
    # Board GPIO table: high selects BMC ownership; low returns flash to BIOS.
    gpioset --mode=signal "$gpiochip" "${line}=${level}" &
    FLASH_SELECT_PID=$!
    FLASH_OWNERSHIP_SELECTED=$level
    sleep 1
    if ! kill -0 "$FLASH_SELECT_PID" 2>/dev/null; then
        echo "ERROR: Failed to hold $FLASH_SELECT_GPIO at level $level" >&2
        FLASH_SELECT_PID=""
        return 1
    fi
}

request_power_transition() {
    local transition=$1 wanted=$2
    busctl set-property xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis RequestedPowerTransition \
        s "xyz.openbmc_project.State.Chassis.Transition.${transition}"
    for _ in {1..60}; do
        [[ "$(power_status 2>/dev/null || true)" == "$wanted" ]] && return 0
        sleep 1
    done
    echo "ERROR: Host did not reach power state $wanted after transition $transition" >&2
    return 1
}

cleanup() {
    local result=$?
    trap - EXIT
    if (( FLASH_OWNERSHIP_SELECTED )); then
        if ! set_flash_select 0; then
            echo "ERROR: Could not restore BIOS flash ownership to the host." >&2
            result=1
        fi
    fi
    if [[ -n "$FLASH_SELECT_PID" ]]; then
        kill "$FLASH_SELECT_PID" 2>/dev/null || true
        wait "$FLASH_SELECT_PID" 2>/dev/null || true
    fi
    exit "$result"
}
trap cleanup EXIT

echo "BIOS update started at $(date); host is confirmed off."
echo "Selecting BMC ownership of BIOS flash via $FLASH_SELECT_GPIO"
set_flash_select 1
sleep 5
reprobe_bios_spi_nor
sleep 1
MTD_DEV=$(find_bios_mtd)
echo "Writing $IMAGE_FILE to AST2600 SPI1 partition $MTD_DEV"
flashrom -p "linux_mtd:dev=${MTD_DEV}" -w "$IMAGE_FILE"

echo "BIOS flash completed; restoring BIOS ownership."
set_flash_select 0
sleep 1
HOST_POWER=$(power_status) || {
    echo "ERROR: Unable to determine host power state after BIOS flash." >&2
    exit 1
}
if [[ "$HOST_POWER" == on ]]; then
    echo "Requesting host ForceOff through the OpenBMC chassis power manager."
    request_power_transition Off off
else
    if [[ "$HOST_POWER" != off ]]; then
        wait_for_host_off
    fi
    echo "Issuing the required ForceOff power-button pulse while host is already in S5/Off."
    busctl call xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis ForcePowerButtonOff
    sleep "$FORCE_OFF_PULSE_S"
    [[ "$(power_status)" == off ]] || {
        echo "ERROR: Host left Off state during the ForceOff pulse; refusing automatic power-on." >&2
        exit 1
    }
fi
echo "Requesting host power-on through the OpenBMC chassis power manager."
request_power_transition On on
echo "BIOS update and host power cycle completed at $(date)."
