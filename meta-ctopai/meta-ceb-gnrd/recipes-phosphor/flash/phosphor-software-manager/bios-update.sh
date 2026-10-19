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
REBOOT_GUARD_HELD=0
PERSISTENT_MARKER_DIRTY=0
BIOS_SPI_DEVICE=""
readonly BIOS_SPI_COMPATIBLE="ctopai,ceb-gnrd-host-bios"
readonly OWNERSHIP_MARKER=/run/ceb-gnrd-bios-flash-held
readonly PERSISTENT_MARKER=/var/lib/ceb-gnrd/bios-flash-held
readonly OWNER_SERVICE=ceb-gnrd-bios-flash-owner.service
readonly RECOVERY_SERVICE=ceb-gnrd-bios-flash-recover.service
readonly POWER_CONTROL_SERVICE=xyz.openbmc_project.Chassis.Control.Power@0.service
RECOVER_ONLY=0
BOOT_RECOVERY=0
RECOVERY_PENDING=0
MANUAL_RECOVERY=0
RESUME_POWER_CONTROL=0

if [[ $# -eq 1 && "$1" == --boot-recover-ownership ]]; then
    RECOVER_ONLY=1
    BOOT_RECOVERY=1
elif [[ $# -eq 1 && ( "$1" == --recover-ownership || "$1" == --recover-if-held ) ]]; then
    RECOVER_ONLY=1
    if [[ "$1" == --recover-ownership ]]; then
        MANUAL_RECOVERY=1
    fi
    if [[ "$1" == --recover-if-held && ! -e "$OWNERSHIP_MARKER" && ! -e "$PERSISTENT_MARKER" ]]; then
        exit 0
    fi
elif [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: $0 <directory-containing-BIOS-image> | --recover-ownership" >&2
    exit 2
fi

# Block host starts before boot recovery can fail, including old firmware's
# lost /run marker. Manual recovery first obtains the programmer locks below.
if (( RECOVER_ONLY )); then
    if [[ -e "$OWNERSHIP_MARKER" || -e "$PERSISTENT_MARKER" ]]; then
        RECOVERY_PENDING=1
    fi
    if (( BOOT_RECOVERY )); then
        mkdir -p "$OWNERSHIP_MARKER"
    fi
fi

# Serialize ownership changes and writes, including manually invoked updates.
mkdir -p /run/lock
exec 9>/run/lock/ceb-gnrd-bios-update.lock
flock -n 9 || {
    echo "ERROR: Another BIOS update is already running." >&2
    exit 1
}

# Web uploads hold a shared lock too; CPLD programming owns it exclusively.
exec 8>/run/lock/ceb-gnrd-cpld-update.lock
flock -s -n 8 || {
    echo "ERROR: A CPLD update is active; BIOS update is blocked." >&2
    exit 1
}
if (( RECOVER_ONLY && ! BOOT_RECOVERY )); then
    mkdir -p "$OWNERSHIP_MARKER"
fi

# Recheck after acquiring the update locks. A static BMC update remains pending
# until reboot, including if bmcweb or the software updater daemon restarted.
if (( ! RECOVER_ONLY )) && [[ -e /run/initramfs/bmc-partitions.txt ||
                            -e /run/initramfs/ceb-gnrd-update-incomplete ]]; then
    echo "ERROR: BMC firmware update is staged; restart the BMC before updating BIOS." >&2
    exit 1
fi
if (( ! RECOVER_ONLY )) && [[ -e "$OWNERSHIP_MARKER" || -e "$PERSISTENT_MARKER" ]]; then
    echo "ERROR: BIOS ownership recovery required: bios-update.sh --recover-ownership" >&2
    exit 1
fi

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
        *"PowerState.Off"*)
            # Generic Off also includes a pending power-on/cycle delay.
            # Require the board state machine's stable Off indication.
            state=$(busctl get-property xyz.openbmc_project.State.Chassis \
                /xyz/openbmc_project/state/chassis0 \
                xyz.openbmc_project.State.Chassis FirmwareProgrammingAllowed \
                2>/dev/null) || return 2
            case "$state" in
                'b true') echo off ;;
                'b false') echo transitioning ;;
                *) return 2 ;;
            esac
            ;;
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

if (( ! RECOVER_ONLY )); then
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
fi

# Power-control rejects software On/Reset/Cycle requests while this lock is
# held. Acquire before checking Off so no new request races flash selection.
exec 7>/run/lock/ceb-gnrd-host-flash.lock
flock -n 7 || {
    echo "ERROR: Another host firmware programmer is active." >&2
    exit 1
}
# Returning ownership only drives the mux low, so it is also safe when the
# host is already running. Boot recovery must not wait for power-control's
# D-Bus service: that service starts only after this recovery has completed.
if (( ! RECOVER_ONLY )); then
    wait_for_host_off
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

find_bios_spi_device() {
    local device
    local matches=()
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
}

wait_for_recovery_devices() {
    local deadline=$((SECONDS + 10))
    # udev-trigger completion does not guarantee that deferred probes have
    # registered both devices. Keep the host interlock while waiting briefly.
    while (( SECONDS < deadline )); do
        if find_bios_spi_device >/dev/null 2>&1 &&
            timeout -k 1 1 gpiofind "$FLASH_SELECT_GPIO" >/dev/null 2>&1; then
            return 0
        fi
        (( SECONDS >= deadline )) || sleep 1
    done
    echo "ERROR: BIOS SPI device or $FLASH_SELECT_GPIO was not ready within 10 seconds; host starts remain blocked." >&2
    return 1
}

reprobe_bios_spi_nor() {
    local driver_dir=/sys/bus/spi/drivers/spi-nor
    [[ -w "$driver_dir/bind" ]] || return 1
    find_bios_spi_device || return 1
    [[ ! -e "$BIOS_SPI_DEVICE/driver" ]] || {
        echo "ERROR: BIOS SPI device is already bound; refusing concurrent access." >&2
        return 1
    }
    printf '%s\n' spi-nor > "$BIOS_SPI_DEVICE/driver_override"
    printf '%s' "${BIOS_SPI_DEVICE##*/}" > "$driver_dir/bind"
    [[ -e "$BIOS_SPI_DEVICE/driver" ]] || return 1
}

release_bios_spi_nor() {
    # Recovery may follow a killed updater, or discovery itself may have
    # failed. Unknown binding state is not permission to hand back the chip.
    if [[ -z "$BIOS_SPI_DEVICE" ]]; then
        find_bios_spi_device || return 1
    fi
    # The unbind worker owns this lock until it exits. A stuck kernel remove
    # may already have removed the driver symlink; a retry must not mistake
    # that for a completed detach and hand back the flash while it is busy.
    if ! timeout -k 2 15 flock -n /run/lock/ceb-gnrd-bios-spi-detach.lock \
        bash -ec '
            device=$1
            if [[ -e "$device/driver" ]]; then
                [[ "$(readlink -f "$device/driver")" == /sys/bus/spi/drivers/spi-nor ]] || {
                    echo "ERROR: BIOS SPI device has an unexpected driver." >&2
                    exit 1
                }
                printf "%s" "${device##*/}" > /sys/bus/spi/drivers/spi-nor/unbind
                [[ ! -e "$device/driver" ]]
            fi
            printf "\n" > "$device/driver_override"
        ' _ "$BIOS_SPI_DEVICE"; then
        echo "ERROR: Timed out or failed detaching BIOS SPI; retaining the host interlock." >&2
        return 1
    fi
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
    sleep 1
    if ! kill -0 "$FLASH_SELECT_PID" 2>/dev/null; then
        echo "ERROR: Failed to hold $FLASH_SELECT_GPIO at level $level" >&2
        FLASH_SELECT_PID=""
        return 1
    fi
}

return_flash_to_host() {
    # Caller has already detached the SPI driver. Keep the marker/host lock
    # across the GPIO handoff, including if stop or gpioset fails.
    timeout -k 2 10 systemctl stop "$OWNER_SERVICE" || return 1
    set_flash_select 0 || return 1
    # The persistent record is cleared only after SPI detach and the GPIO
    # hand-back succeed. A read-only/full rwfs leaves a diagnosable interlock.
    if [[ -e "$PERSISTENT_MARKER" ]]; then
        PERSISTENT_MARKER_DIRTY=1
        rm "$PERSISTENT_MARKER" || return 1
    fi
    if (( PERSISTENT_MARKER_DIRTY )); then
        timeout -k 2 15 sync || return 1
        PERSISTENT_MARKER_DIRTY=0
    fi
    rmdir "$OWNERSHIP_MARKER" || return 1
    FLASH_OWNERSHIP_SELECTED=0
}

retain_flash_fault() {
    # Never select high while recovering: the host may already be running
    # after a BMC restart. Preserve the interlock and any existing holder.
    mkdir -p "$OWNERSHIP_MARKER" || true
    local message="BIOS ownership recovery failed; host starts remain blocked. Run bios-update.sh --recover-ownership after resolving SPI/GPIO/storage errors."
    echo "ERROR: $message" >&2
    logger -p user.err -t bios-update "$message" || true
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
    trap '' HUP INT TERM
    set +e
    if (( FLASH_OWNERSHIP_SELECTED )); then
        if (( result != 0 )); then
            echo "ERROR: BIOS operation failed (status $result); attempting to return flash ownership to BIOS." >&2
        fi
        if ! release_bios_spi_nor || ! return_flash_to_host; then
            retain_flash_fault
            result=1
        elif (( result != 0 )); then
            logger -p user.warning -t bios-update \
                "BIOS operation failed; flash ownership returned to BIOS. Image validity is unknown; host power-on was not requested." || true
        fi
    fi
    if [[ -n "$FLASH_SELECT_PID" ]]; then
        kill "$FLASH_SELECT_PID" 2>/dev/null || true
        wait "$FLASH_SELECT_PID" 2>/dev/null || true
    fi
    if (( REBOOT_GUARD_HELD )); then
        # The GPIO child inherited this reference, so release after it exits.
        # Close only our own descriptor; another activation may still own one.
        exec 6>&-
        REBOOT_GUARD_HELD=0
        /usr/bin/obmc-flash-bmc rebootguarddisable || result=1
    fi
    if (( RESUME_POWER_CONTROL && result == 0 )); then
        # A failed required boot-recovery unit also prevents power-control
        # from starting. Release all programmer locks before queuing its
        # dependency chain; a new recovery process must be able to acquire
        # them immediately. Keep bios-power-managed to suppress AC restore.
        exec 7>&- 8>&- 9>&-
        if timeout -k 2 10 systemctl reset-failed "$RECOVERY_SERVICE" "$POWER_CONTROL_SERVICE" &&
            timeout -k 2 10 systemctl --no-block start "$RECOVERY_SERVICE" "$POWER_CONTROL_SERVICE"; then
            echo "Power-control service recovery queued; automatic host power-on remains suppressed."
        else
            echo "ERROR: BIOS ownership was returned, but power-control service recovery could not be queued." >&2
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# This reference outlives a restart of the software updater daemon. The
# service's ExecStopPost reconciles the guard after unexpected shell exits.
if (( ! BOOT_RECOVERY )); then
    exec 6>/run/lock/ceb-gnrd-reboot-guard.lock
    flock -s 6
    REBOOT_GUARD_HELD=1
    /usr/bin/obmc-flash-bmc rebootguardenable
fi

# This BIOS operation supersedes this boot's pending AC restore policy, even
# if that timer expires after ownership has been released. A successful update
# performs its own power cycle; ownership-only recovery must not boot an
# unverified image. /run clears this decision at the next BMC boot.
if (( ! BOOT_RECOVERY || RECOVERY_PENDING )); then
    : > /run/ceb-gnrd-bios-power-managed
fi

if (( RECOVER_ONLY )); then
    if (( BOOT_RECOVERY )); then
        wait_for_recovery_devices
    fi
    FLASH_OWNERSHIP_SELECTED=1
    find_bios_spi_device
    release_bios_spi_nor
    return_flash_to_host
    # Stop-post recovery must not start services. Only an explicit manual
    # recovery repairs the service chain after a failed boot recovery.
    RESUME_POWER_CONTROL=$MANUAL_RECOVERY
    echo "BIOS ownership returned to host. No host power transition requested; image validity has not been checked."
    exit 0
fi

echo "BIOS update started at $(date); host is confirmed off."
echo "Selecting BMC ownership of BIOS flash via $FLASH_SELECT_GPIO"
set_progress 25
mkdir "$OWNERSHIP_MARKER"
FLASH_OWNERSHIP_SELECTED=1
# Persist intent before the first high level, so a watchdog reset cannot lose
# the unfinished update indication along with /run. Do not select BMC on a
# read-only/full filesystem or a failed flush.
mkdir -p "${PERSISTENT_MARKER%/*}"
: > "$PERSISTENT_MARKER"
timeout -k 2 15 sync
systemctl start "$OWNER_SERVICE"
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
return_flash_to_host
sleep 1
# Flash is detached and owned by the host again; permit the required power cycle.
flock -u 7
exec 7>&-
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
