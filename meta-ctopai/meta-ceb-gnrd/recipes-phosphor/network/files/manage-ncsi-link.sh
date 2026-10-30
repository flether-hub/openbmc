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
readonly POST_SETTLE_SECONDS=5
readonly DHCP_WAIT_SECONDS=60
readonly DHCP_MAX_RECOVERIES=3
readonly DHCP_CHECK_INTERVAL=5
readonly NETWORK_SERVICE=xyz.openbmc_project.Network
readonly NETWORK_PATH=/xyz/openbmc_project/network/eth1
readonly NETWORK_INTERFACE=xyz.openbmc_project.Network.EthernetInterface

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
    [ "$gate" = ready ] || return
    enabled=$(busctl --timeout=2s get-property "$NETWORK_SERVICE" "$NETWORK_PATH" \
        "$NETWORK_INTERFACE" NICEnabled 2>/dev/null || true)
    case "$enabled" in
        'b true') ;;
        'b false') gate=disabled ;;
        *) gate=unknown ;;
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

# A carrier alone does not prove that the NC-SI data path recovered after
# host power loss. Preserve working IPv6-only and static configurations too.
# Return 2 for an inspection failure: never bounce a link we cannot inspect.
has_network_address() {
    addresses=$(ip -o address show dev "$IFACE" scope global 2>/dev/null) || return 2
    printf '%s\n' "$addresses" | awk '
        / tentative| dadfailed/ { next }
        $3 == "inet" && $4 !~ /^(169\.254\.|127\.|0\.)/ { found = 1 }
        $3 == "inet6" { found = 1 }
        END { exit !found }
    '
}

dhcp4_is_enabled() {
    dhcp4=$(busctl --timeout=2s get-property "$NETWORK_SERVICE" "$NETWORK_PATH" \
        "$NETWORK_INTERFACE" DHCP4 2>/dev/null || true)
    [ "$dhcp4" = 'b true' ]
}

check_startup_dhcp() {
    [ "$startup_address_seen" -eq 0 ] || return 0
    [ "$now" -ge "$next_dhcp_check" ] || return 0
    next_dhcp_check=$((now + DHCP_CHECK_INTERVAL))

    if has_network_address; then
        startup_address_seen=1
        dhcp_wait_since=0
        logger -p user.info -t ceb-gnrd-ncsi "$IFACE usable address acquired; startup DHCP recovery disarmed"
        return 0
    else
        address_status=$?
    fi
    if [ "$address_status" -ne 1 ] || ! dhcp4_is_enabled; then
        dhcp_wait_since=0
        return 0
    fi
    [ "$dhcp_recoveries" -lt "$DHCP_MAX_RECOVERIES" ] || return 0
    if [ "$dhcp_wait_since" -eq 0 ]; then
        dhcp_wait_since=$now
        return 0
    fi
    [ "$((now - dhcp_wait_since))" -ge "$DHCP_WAIT_SECONDS" ] || return 0

    # Settings or power state may have changed during the DHCP grace period.
    # Recheck before touching the interface; unknown queries cannot authorize it.
    read_gate
    [ "$gate" = ready ] || return 0
    dhcp4_is_enabled || return 0
    if has_network_address; then
        startup_address_seen=1
        return 0
    else
        [ "$?" -eq 1 ] || return 0
    fi
    link_is_up && has_carrier || return 0

    dhcp_recoveries=$((dhcp_recoveries + 1))
    dhcp_wait_since=0
    logger -p user.warning -t ceb-gnrd-ncsi "$IFACE carrier present but no usable address after ${DHCP_WAIT_SECONDS}s; NC-SI down/up recovery ${dhcp_recoveries}/${DHCP_MAX_RECOVERIES}"
    if ! link_error=$(ip link set dev "$IFACE" down 2>&1); then
        logger -p user.warning -t ceb-gnrd-ncsi "DHCP recovery could not lower $IFACE: $link_error"
        return 0
    fi
    sleep 1
    read_gate
    if [ "$gate" = ready ]; then
        if ! link_error=$(ip link set dev "$IFACE" up 2>&1); then
            logger -p user.warning -t ceb-gnrd-ncsi "DHCP recovery could not raise $IFACE: $link_error"
        fi
    fi
    if [ "$dhcp_recoveries" -ge "$DHCP_MAX_RECOVERIES" ]; then
        logger -p user.warning -t ceb-gnrd-ncsi "$IFACE startup DHCP recovery limit reached; no further DHCP-triggered resets this host/POST cycle"
    fi
}

last_gate=initial
last_carrier=unknown
next_attempt=0
retries=0
interface_missing=0
had_carrier=0
query_paused=0
startup_address_seen=0
dhcp_wait_since=0
dhcp_recoveries=0
next_dhcp_check=0
while :; do
    read_gate
    now=$(monotonic_seconds)
    # Unknown is a query outage, not a confirmed host or management transition.
    # Keep carrier and retry history so recovery cannot reprobe a known channel.
    if [ "$gate" = unknown ]; then
        dhcp_wait_since=0
        if [ "$query_paused" -eq 0 ]; then
            logger -p user.info -t ceb-gnrd-ncsi "host/POST state unavailable; NC-SI initialization paused"
            query_paused=1
        fi
        sleep 1
        continue
    fi
    if [ "$query_paused" -eq 1 ]; then
        logger -p user.info -t ceb-gnrd-ncsi "state queries recovered; resuming NC-SI management"
        query_paused=0
    fi
    if [ "$gate" != "$last_gate" ]; then
        last_gate=$gate
        retries=0
        next_attempt=$now
        last_carrier=unknown
        had_carrier=0
        startup_address_seen=0
        dhcp_wait_since=0
        dhcp_recoveries=0
        next_dhcp_check=0
        case "$gate" in
            ready)
                next_attempt=$((now + POST_SETTLE_SECONDS))
                logger -p user.info -t ceb-gnrd-ncsi "BIOS POST complete; allowing ${POST_SETTLE_SECONDS}s for NIC readiness before enabling $IFACE"
                ;;
            off) logger -p user.info -t ceb-gnrd-ncsi "host off; disabling $IFACE and stopping initialization" ;;
            disabled) logger -p user.info -t ceb-gnrd-ncsi "$IFACE administratively disabled; stopping initialization" ;;
            post) logger -p user.info -t ceb-gnrd-ncsi "waiting for BIOS POST complete; disabling $IFACE" ;;
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
        had_carrier=1
        retries=0
        next_attempt=$((now + RETRY_INTERVAL))
        if [ "$last_carrier" != 1 ]; then
            logger -p user.info -t ceb-gnrd-ncsi "$IFACE NC-SI carrier acquired"
            last_carrier=1
        fi
        check_startup_dhcp
    elif link_is_up && [ "$had_carrier" -eq 1 ]; then
        dhcp_wait_since=0
        # Cable/carrier loss after a successful connection is monitored by
        # the kernel. Do not repeatedly restart a discovered NC-SI channel.
        if [ "$last_carrier" != 0 ]; then
            logger -p user.info -t ceb-gnrd-ncsi "$IFACE carrier lost; keeping the discovered channel active for link recovery"
            last_carrier=0
        fi
    elif [ "$now" -ge "$next_attempt" ]; then
        dhcp_wait_since=0
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
