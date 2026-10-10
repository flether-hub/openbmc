#!/bin/sh
# The host-powered E810 is usable only after BIOS POST complete. power-control
# owns BMC_BIOS_BOOT_OK and publishes it as OperatingSystemState=Standby.
set -u

readonly IFACE=eth1
readonly CHASSIS_SERVICE=xyz.openbmc_project.State.Chassis
readonly CHASSIS_PATH=/xyz/openbmc_project/state/chassis0
readonly CHASSIS_INTERFACE=xyz.openbmc_project.State.Chassis
readonly OS_SERVICE=xyz.openbmc_project.State.OperatingSystem
readonly OS_PATH=/xyz/openbmc_project/state/host0
readonly OS_INTERFACE=xyz.openbmc_project.State.OperatingSystem.Status
readonly RETRY_INTERVAL=30
readonly MAX_RETRIES=3
readonly RECOVERY_INTERVAL=300

read_gate() {
    gate=unknown
    state=$(busctl --timeout=2s get-property "$CHASSIS_SERVICE" "$CHASSIS_PATH" \
        "$CHASSIS_INTERFACE" CurrentPowerState 2>/dev/null || true)
    case "$state" in
        's "xyz.openbmc_project.State.Chassis.PowerState.Off"')
            gate=off
            return
            ;;
        's "xyz.openbmc_project.State.Chassis.PowerState.On"') ;;
        *) return ;;
    esac
    os_state=$(busctl --timeout=2s get-property "$OS_SERVICE" "$OS_PATH" \
        "$OS_INTERFACE" OperatingSystemState 2>/dev/null || true)
    case "$os_state" in
        's "xyz.openbmc_project.State.OperatingSystem.Status.OSStatus.Standby"')
            gate=ready ;;
        's "xyz.openbmc_project.State.OperatingSystem.Status.OSStatus.Inactive"')
            gate=post ;;
    esac
}

link_is_up() {
    [ -r "/sys/class/net/$IFACE/flags" ] || return 1
    read -r link_flags < "/sys/class/net/$IFACE/flags" || return 1
    [ $((link_flags & 1)) -ne 0 ]
}

has_carrier() {
    [ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)" = 1 ]
}

monotonic_seconds() {
    read -r uptime_seconds unused < /proc/uptime
    echo "${uptime_seconds%%.*}"
}

last_gate=initial
last_carrier=unknown
next_attempt=0
retries=0
interface_missing=0
while :; do
    read_gate
    now=$(monotonic_seconds)
    if [ "$gate" != "$last_gate" ]; then
        last_gate=$gate
        retries=0
        next_attempt=$now
        last_carrier=unknown
        case "$gate" in
            ready) logger -p user.info -t ceb-gnrd-ncsi "BIOS POST complete; enabling $IFACE" ;;
            off) logger -p user.info -t ceb-gnrd-ncsi "host off; disabling $IFACE and stopping initialization" ;;
            post) logger -p user.info -t ceb-gnrd-ncsi "waiting for BIOS POST complete; disabling $IFACE" ;;
            unknown) logger -p user.info -t ceb-gnrd-ncsi "host/POST state unavailable; NC-SI initialization paused" ;;
        esac
    fi

    if [ ! -d "/sys/class/net/$IFACE" ]; then
        if [ "$interface_missing" -eq 0 ]; then
            logger -p user.info -t ceb-gnrd-ncsi "$IFACE not present; waiting for interface"
            interface_missing=1
        fi
        sleep 1
        continue
    fi
    interface_missing=0

    # Missing D-Bus state never authorizes an up/reprobe. Preserve an existing
    # link across a temporary service outage, until state is known again.
    if [ "$gate" = unknown ]; then
        sleep 1
        continue
    fi

    if [ "$gate" != ready ]; then
        # Off or POST withdrawal immediately lowers an active interface.
        # Already down is expected and requires no ip command.
        if link_is_up && [ "$now" -ge "$next_attempt" ]; then
            next_attempt=$((now + RETRY_INTERVAL))
            if link_error=$(ip link set dev "$IFACE" down 2>&1); then
                logger -p user.info -t ceb-gnrd-ncsi "$IFACE lowered; NC-SI retries stopped"
            else
                logger -p user.warning -t ceb-gnrd-ncsi "could not lower $IFACE: $link_error"
            fi
        fi
        sleep 1
        continue
    fi

    if link_is_up && has_carrier; then
        retries=0
        next_attempt=$((now + RETRY_INTERVAL))
        if [ "$last_carrier" != 1 ]; then
            logger -p user.info -t ceb-gnrd-ncsi "$IFACE NC-SI carrier acquired"
            last_carrier=1
        fi
    elif [ "$now" -ge "$next_attempt" ]; then
        # Timestamp failures too. Three quick attempts then slow recovery.
        retries=$((retries + 1))
        interval=$RETRY_INTERVAL
        if [ "$retries" -ge "$MAX_RETRIES" ]; then
            interval=$RECOVERY_INTERVAL
            retries=$MAX_RETRIES
        fi
        next_attempt=$((now + interval))
        last_carrier=0
        if link_is_up; then
            if ! link_error=$(ip link set dev "$IFACE" down 2>&1); then
                logger -p user.warning -t ceb-gnrd-ncsi "NC-SI retry could not lower $IFACE: $link_error"
                sleep 1
                continue
            fi
            sleep 1
        fi
        # Shutdown/reset may have happened while lowering the link. Recheck
        # both conditions before requesting new NC-SI initialization.
        read_gate
        if [ "$gate" != ready ]; then
            continue
        fi
        if link_error=$(ip link set dev "$IFACE" up 2>&1); then
            logger -p user.info -t ceb-gnrd-ncsi "$IFACE initialization requested; next retry in ${interval}s if no carrier"
        else
            logger -p user.warning -t ceb-gnrd-ncsi "$IFACE initialization failed after POST complete: $link_error; next retry in ${interval}s"
        fi
        now=$(monotonic_seconds)
        next_attempt=$((now + interval))
    fi
    sleep 1
done
