#!/bin/sh
# The Intel E810 behind the NC-SI link has no standby power: it only answers
# once the host is powered.  Keep eth1 down while the host is off and raise it
# when the chassis power state becomes On.
#
# The E810 is not necessarily ready the moment BMC_CPU_PWRGD goes high, and the
# kernel NC-SI stack gives up after one failed probe.  So while the host is on
# but eth1 still has no carrier, cycle the link (down/up) at intervals so the
# NC-SI probe is repeated until the E810 answers.

set -u

readonly IFACE=eth1
readonly CHASSIS_SERVICE=xyz.openbmc_project.State.Chassis
readonly CHASSIS_PATH=/xyz/openbmc_project/state/chassis0
readonly CHASSIS_INTERFACE=xyz.openbmc_project.State.Chassis
readonly RETRY_INTERVAL=30   # seconds without carrier before the link is cycled
readonly MAX_RETRIES=40      # about 20 minutes, then keep the last attempt up

set_link_state() {
    desired=$1
    if [ "$desired" = on ]; then
        ip link set dev "$IFACE" up
    else
        ip link set dev "$IFACE" down
    fi
}

has_carrier() {
    [ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)" = 1 ]
}

last_state=unknown
retries=0
last_up=0
while :; do
    state=$(busctl get-property "$CHASSIS_SERVICE" "$CHASSIS_PATH" \
        "$CHASSIS_INTERFACE" CurrentPowerState 2>/dev/null || true)

    case "$state" in
        *PowerState.On*) desired=on ;;
        *) desired=off ;;
    esac

    now=$(date +%s)
    if [ "$desired" != "$last_state" ]; then
        if set_link_state "$desired"; then
            logger -t ceb-gnrd-ncsi "eth1 set $desired for chassis power state"
            last_state=$desired
            retries=0
            last_up=$now
        else
            logger -t ceb-gnrd-ncsi "failed to set eth1 $desired; will retry"
        fi
    elif [ "$desired" = on ]; then
        if has_carrier; then
            retries=0
        elif [ $((now - last_up)) -ge "$RETRY_INTERVAL" ] && [ "$retries" -lt "$MAX_RETRIES" ]; then
            retries=$((retries + 1))
            logger -t ceb-gnrd-ncsi "eth1 has no NC-SI link, cycling it (attempt $retries/$MAX_RETRIES)"
            ip link set dev "$IFACE" down
            sleep 1
            ip link set dev "$IFACE" up
            last_up=$(date +%s)
        fi
    fi

    sleep 1
done
