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
readonly MAX_RETRIES=3       # quick attempts, including a failed initial up/down
readonly RECOVERY_INTERVAL=300 # slow recovery after quick attempts are exhausted

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

# RTC/NTP changes must not bypass the retry interval.
monotonic_seconds() {
    read -r uptime_seconds unused < /proc/uptime
    echo "${uptime_seconds%%.*}"
}

last_state=unknown
last_carrier=unknown
retries=0
last_attempt=0
pending=1
state_unavailable=0
while :; do
    state=$(busctl get-property "$CHASSIS_SERVICE" "$CHASSIS_PATH" \
        "$CHASSIS_INTERFACE" CurrentPowerState 2>/dev/null || true)

    case "$state" in
        *PowerState.On*) desired=on ;;
        *PowerState.Off*) desired=off ;;
        *)
            if [ "$state_unavailable" -eq 0 ]; then
                logger -t ceb-gnrd-ncsi "chassis state unavailable; retaining eth1 state"
                state_unavailable=1
            fi
            sleep 1
            continue
            ;;
    esac
    state_unavailable=0

    now=$(monotonic_seconds)
    if [ "$desired" != "$last_state" ]; then
        # Record the requested state even if ip fails. Retry through the same
        # timed path instead of treating every poll as a new transition.
        last_state=$desired
        pending=1
        retries=0
        last_attempt=$((now - RETRY_INTERVAL))
    fi

    if [ "$desired" = on ] && [ "$pending" -eq 0 ] && has_carrier; then
        retries=0
        last_attempt=$now
    elif [ "$pending" -eq 1 ] || [ "$desired" = on ]; then
        interval=$RETRY_INTERVAL
        if [ "$retries" -ge "$MAX_RETRIES" ]; then
            interval=$RECOVERY_INTERVAL
        fi
        if [ $((now - last_attempt)) -ge "$interval" ]; then
            # Count and timestamp failures too, including failed link-down.
            last_attempt=$now
            if [ "$retries" -lt "$MAX_RETRIES" ]; then
                retries=$((retries + 1))
            fi
            if [ "$pending" -eq 0 ]; then
                logger -t ceb-gnrd-ncsi "eth1 has no NC-SI carrier; retry interval=${interval}s"
                if ip link set dev "$IFACE" down; then
                    pending=1
                    sleep 1
                else
                    logger -t ceb-gnrd-ncsi "failed to lower eth1; timed retry pending"
                    sleep 1
                    continue
                fi
            fi
            if set_link_state "$desired"; then
                pending=0
                logger -t ceb-gnrd-ncsi "eth1 set $desired; retries=$retries"
            else
                logger -t ceb-gnrd-ncsi "failed to set eth1 $desired; timed retry pending"
            fi
            last_attempt=$(monotonic_seconds)
        fi
    fi

    carrier=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo unknown)
    if [ "$carrier" != "$last_carrier" ]; then
        logger -t ceb-gnrd-ncsi "eth1 carrier=$carrier chassis=$desired retries=$retries"
        last_carrier=$carrier
    fi
    sleep 1
done
