#!/bin/bash
# 通过 AST2600 SPI1 更新 BIOS NOR；BMC 启动 Flash 位于 Firmware SPI/FMC。
set -euo pipefail

readonly FLASH_SELECT_GPIO="BMC_BIOS_FLASH_SELECT"
readonly MTD_PARTITION_NAME="host-bios"
readonly EXPECTED_FLASH_SIZE=67108864
readonly HOST_SHUTDOWN_TIMEOUT_S=1800
readonly HOST_OFF_STABLE_S=3
# Must be longer than ForceOffPulseMs (8000 ms) in x86-power-control's power-config-host0.json.
readonly FORCE_OFF_PULSE_S=9
FLASH_SELECT_PID=""
FLASH_OWNERSHIP_SELECTED=0
BIOS_SPI_DEVICE=""
readonly BIOS_SPI_COMPATIBLE="ctopai,ceb-gnrd-host-bios"

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: $0 <directory-containing-BIOS-image>" >&2
    exit 2
fi

# Serialize ownership changes and writes, including manually invoked updates.
mkdir -p /run/lock
exec 9>/run/lock/ceb-gnrd-bios-update.lock
flock -n 9 || {
    echo "ERROR: Another BIOS update is already running." >&2
    exit 1
}

# Progress for the web page: the image directory is /tmp/images/<version id>, and the
# software manager's object of this update is /xyz/openbmc_project/software/<id>.
# Its ActivationProgress.Progress (0-100) becomes PercentComplete of the Redfish
# update task, which the firmware page polls; the page names the step from the
# value, so keep these numbers in sync with FirmwareFormUpdate.vue (webui patch 0013):
#   20 started (set by the software manager)   21/22 waiting for the host to be off
#   25 switching the BIOS flash to the BMC     28 detecting the flash
#   30-40 reading the flash   40-55 erasing   55-85 writing   85-88 verifying
#   89 returning the flash to the BIOS         92 force-off power-button pulse
#   95 powering the host on                    100 done (set by the software manager)
# bmcweb cancels the task after 5 minutes without a progress change, so long waits
# change the value at least once a minute.  Run by hand (no such object) the
# updates are silently ignored.
readonly SOFTWARE_PATH="/xyz/openbmc_project/software/$(basename "$1")"
LAST_PROGRESS=""
set_progress() {
    [[ "$1" == "$LAST_PROGRESS" ]] && return 0
    LAST_PROGRESS=$1
    busctl set-property xyz.openbmc_project.Software.BMC.Updater "$SOFTWARE_PATH" \
        xyz.openbmc_project.Software.ActivationProgress Progress y "$1" \
        >/dev/null 2>&1 || true
}

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

    set_progress 21
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

        # keep the web progress (and the Redfish task) alive while waiting
        if (( elapsed > 0 && elapsed % 60 == 0 )); then
            set_progress $(( LAST_PROGRESS == 21 ? 22 : 21 ))
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

IMAGE_FILE=$(find "$1" -type f \( -iname '*.fd' -o -iname '*.bin' \) -print -quit)
if [[ -z "$IMAGE_FILE" ]]; then
    echo "ERROR: BIOS image (.FD/.BIN) not found in $1" >&2
    exit 1
fi
if (( $(stat -c %s "$IMAGE_FILE") != EXPECTED_FLASH_SIZE )); then
    echo "ERROR: $IMAGE_FILE is $(stat -c %s "$IMAGE_FILE") bytes; a full $EXPECTED_FLASH_SIZE-byte flash image is required." >&2
    exit 1
fi

# Flash regions.  The layout of the board's BIOS flash is fixed (flashrom format,
# "start:end name", hex): /usr/share/ceb-gnrd/bios-layout.txt.  The regions to
# write come from bios-regions.txt in the package (one name per line, added by the
# web firmware page); without it every region except nac0/nac1 is written.
# nac0/nac1 hold the configuration of the CPU's integrated network controller,
# including its MAC addresses, which a full image would overwrite.  Regions not
# selected keep their current content.
readonly LAYOUT_FILE=/usr/share/ceb-gnrd/bios-layout.txt
readonly DEFAULT_SKIPPED_REGIONS="nac0 nac1"
if [[ ! -r "$LAYOUT_FILE" ]]; then
    echo "ERROR: BIOS flash layout $LAYOUT_FILE not found." >&2
    exit 1
fi
LAYOUT_REGIONS=()
while read -r range name _; do
    [[ -z "${range:-}" || "$range" == \#* ]] && continue
    start=-1; end=-1
    if [[ "$range" =~ ^([0-9a-fA-F]+):([0-9a-fA-F]+)$ ]]; then
        start=$(( 16#${BASH_REMATCH[1]} )); end=$(( 16#${BASH_REMATCH[2]} ))
    fi
    if (( start < 0 || start > end || end >= EXPECTED_FLASH_SIZE )) ||
        [[ ! "${name:-}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "ERROR: bad line in $LAYOUT_FILE: $range ${name:-}" >&2
        exit 1
    fi
    LAYOUT_REGIONS+=("$name")
done < "$LAYOUT_FILE"
if (( ${#LAYOUT_REGIONS[@]} == 0 )); then
    echo "ERROR: $LAYOUT_FILE lists no regions." >&2
    exit 1
fi
SELECTED_REGIONS=()
if [[ -f "$1/bios-regions.txt" ]]; then
    while read -r name _; do
        [[ -z "${name:-}" || "$name" == \#* ]] && continue
        if [[ " ${LAYOUT_REGIONS[*]} " != *" $name "* ]]; then
            echo "ERROR: region '$name' in bios-regions.txt is not in $LAYOUT_FILE" >&2
            exit 1
        fi
        SELECTED_REGIONS+=("$name")
    done < "$1/bios-regions.txt"
else
    for name in "${LAYOUT_REGIONS[@]}"; do
        [[ " $DEFAULT_SKIPPED_REGIONS " == *" $name "* ]] || SELECTED_REGIONS+=("$name")
    done
fi
if (( ${#SELECTED_REGIONS[@]} == 0 )); then
    echo "ERROR: no BIOS flash region selected." >&2
    exit 1
fi
echo "BIOS flash layout: $LAYOUT_FILE (${LAYOUT_REGIONS[*]})"
echo "Regions to write: ${SELECTED_REGIONS[*]}"
for name in "${LAYOUT_REGIONS[@]}"; do
    [[ " ${SELECTED_REGIONS[*]} " == *" $name "* ]] || echo "Region kept unchanged: $name"
done

wait_for_host_off

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
    local matches=()
    [[ -w "$driver_dir/bind" ]] || {
        echo "ERROR: SPI-NOR driver binding is unavailable." >&2
        return 1
    }
    # This board-only compatible has no automatic driver match. Never touch
    # another SPI device, particularly the BMC's own FMC boot flash.
    for device in /sys/bus/spi/devices/spi*; do
        [[ -r "$device/of_node/compatible" ]] || continue
        grep -Faq "$BIOS_SPI_COMPATIBLE" "$device/of_node/compatible" || continue
        matches+=("$device")
    done
    (( ${#matches[@]} == 1 )) || {
        echo "ERROR: Expected exactly one board BIOS SPI device; found ${#matches[@]}." >&2
        return 1
    }
    BIOS_SPI_DEVICE=${matches[0]}
    [[ ! -e "$BIOS_SPI_DEVICE/driver" ]] || {
        echo "ERROR: BIOS SPI device is already bound; refusing concurrent access." >&2
        return 1
    }
    printf '%s\n' spi-nor > "$BIOS_SPI_DEVICE/driver_override"
    printf '%s' "${BIOS_SPI_DEVICE##*/}" > "$driver_dir/bind"
    [[ -e "$BIOS_SPI_DEVICE/driver" ]] || return 1
}

release_bios_spi_nor() {
    [[ -n "$BIOS_SPI_DEVICE" ]] || return 0
    if [[ -e "$BIOS_SPI_DEVICE/driver" ]]; then
        [[ "$(readlink -f "$BIOS_SPI_DEVICE/driver")" == /sys/bus/spi/drivers/spi-nor ]] || {
            echo "ERROR: BIOS SPI device has an unexpected driver." >&2
            return 1
        }
        # Remove MTD access before handing the shared chip back to the CPU.
        printf '%s' "${BIOS_SPI_DEVICE##*/}" > /sys/bus/spi/drivers/spi-nor/unbind || return 1
    fi
    printf '\n' > "$BIOS_SPI_DEVICE/driver_override" || return 1
    BIOS_SPI_DEVICE=""
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
        if ! release_bios_spi_nor; then
            echo "ERROR: Could not detach BIOS MTD; retaining BMC flash ownership. Host must remain off." >&2
            # Keep the GPIO holder alive rather than handing an accessible
            # MTD device to the CPU. Do not automatically power on the host.
            exit 1
        fi
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
trap 'exit 130' INT
trap 'exit 143' TERM

echo "BIOS update started at $(date); host is confirmed off."
echo "Selecting BMC ownership of BIOS flash via $FLASH_SELECT_GPIO"
set_progress 25
set_flash_select 1
sleep 5
set_progress 28
reprobe_bios_spi_nor
sleep 1
MTD_DEV=$(find_bios_mtd)
echo "Writing regions ${SELECTED_REGIONS[*]} of $IMAGE_FILE to AST2600 SPI1 partition $MTD_DEV"
set_progress 30
# flashrom writes only the included regions (erasing and rewriting only blocks that
# differ) and verifies them.  --progress prints "[READ: n%][ERASE: n%][WRITE: n%]..."
# (with backspaces between updates); map reading the current content to 30-40,
# erasing to 40-55, writing to 55-85 and the verify read after the write to 85-88.
# linux_mtd takes the MTD device number, not the device path.
FLASHROM_ARGS=(-p "linux_mtd:dev=${MTD_DEV#/dev/mtd}" -l "$LAYOUT_FILE" --noverify-all --progress)
for name in "${SELECTED_REGIONS[@]}"; do
    FLASHROM_ARGS+=(-i "$name")
done
flashrom "${FLASHROM_ARGS[@]}" -w "$IMAGE_FILE" |
while IFS= read -r -d '.' chunk || [[ -n "$chunk" ]]; do
    # pass flashrom's own messages on to the journal, without the progress counters
    if [[ "$chunk" != *%\]* ]]; then
        printf '%s.' "$chunk"
    fi
    read_pc=""; erase_pc=""; write_pc=""
    [[ "$chunk" =~ \[READ:\ *([0-9]+)%\] ]] && read_pc=${BASH_REMATCH[1]}
    [[ "$chunk" =~ \[ERASE:\ *([0-9]+)%\] ]] && erase_pc=${BASH_REMATCH[1]}
    [[ "$chunk" =~ \[WRITE:\ *([0-9]+)%\] ]] && write_pc=${BASH_REMATCH[1]}
    p=$LAST_PROGRESS
    if [[ "$chunk" == *Verifying* ]]; then
        verifying=1
        p=85
    fi
    if [[ -n "$write_pc" ]]; then
        written=1
        p=$(( 55 + 30 * write_pc / 100 ))
    elif [[ -n "$erase_pc" ]]; then
        p=$(( 40 + 15 * erase_pc / 100 ))
    elif [[ -n "$read_pc" ]]; then
        if [[ -n "${written:-}${verifying:-}" ]]; then
            p=$(( 85 + 3 * read_pc / 100 ))
        else
            p=$(( 30 + 10 * read_pc / 100 ))
        fi
    fi
    # never move backwards (a later stage restarts its own percentage)
    # the loop's last command must succeed (pipefail would stop the script)
    if (( p > LAST_PROGRESS )); then
        set_progress "$p"
    fi
done
echo
set_progress 88

echo "BIOS flash completed; restoring BIOS ownership."
set_progress 89
release_bios_spi_nor
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
    set_progress 92
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
set_progress 95
request_power_transition On on
echo "BIOS update and host power cycle completed at $(date)."
