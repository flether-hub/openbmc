#!/bin/sh

set -u

readonly IFACE=eth1
readonly CHASSIS_SERVICE=xyz.openbmc_project.State.Chassis
readonly CHASSIS_PATH=/xyz/openbmc_project/state/chassis0
readonly CHASSIS_INTERFACE=xyz.openbmc_project.State.Chassis

set_link_state() {
    desired=$1
    if [ "$desired" = on ]; then
        ip link set dev "$IFACE" up
    else
        ip link set dev "$IFACE" down
    fi
}

last_state=unknown
while :; do
    state=$(busctl get-property "$CHASSIS_SERVICE" "$CHASSIS_PATH" \
        "$CHASSIS_INTERFACE" CurrentPowerState 2>/dev/null || true)

    case "$state" in
        *PowerState.On*) desired=on ;;
        *) desired=off ;;
    esac

    if [ "$desired" != "$last_state" ]; then
        if set_link_state "$desired"; then
            logger -t ceb-gnrd-ncsi "eth1 set $desired for chassis power state"
            last_state=$desired
        else
            logger -t ceb-gnrd-ncsi "failed to set eth1 $desired; will retry"
        fi
    fi

    sleep 1
done
