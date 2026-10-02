#!/bin/sh
# CEB-GNRD BMC service health monitor.
#
# The hardware watchdog only notices a hung systemd or kernel.  A service that
# hangs while systemd stays alive (bmcweb, ipmid, Entity-Manager ...) is not
# seen by it, so this monitor probes the important services every INTERVAL
# seconds:
#   * D-Bus services: org.freedesktop.DBus.Peer.Ping, which is answered by the
#     service's own event loop, so a hung loop does not answer
#   * bmcweb: HTTPS GET /redfish/v1/ must return 200
# After FAILS consecutive failures the unit is restarted and a SEL record is
# written.  A unit that had to be restarted RESTART_LIMIT times within
# RESTART_WINDOW seconds, and the object mapper / Entity-Manager when they still
# do not answer after a restart, are escalated to a forced BMC reboot (the SoC
# restarts through the hardware watchdog); at most REBOOT_LIMIT such reboots per
# hour, so a permanent fault cannot cause a reboot loop.
#
# Everything is logged to the journal: journalctl -u ceb-gnrd-health-monitor

INTERVAL=${HEALTH_INTERVAL:-30}
FAILS=${HEALTH_FAILS:-3}
PING_TIMEOUT=${HEALTH_PING_TIMEOUT:-20}
START_DELAY=${HEALTH_START_DELAY:-120}
RESTART_LIMIT=3
RESTART_WINDOW=900
REBOOT_LIMIT=3
REBOOT_WINDOW=3600

RUN=/run/ceb-gnrd-health
STATE=/var/lib/ceb-gnrd/health
mkdir -p "$RUN" "$STATE"

# unit|probe kind|probe target|base service (1 = reboot the BMC when it stays down)
TARGETS="
xyz.openbmc_project.ObjectMapper.service|dbus|xyz.openbmc_project.ObjectMapper|1
xyz.openbmc_project.EntityManager.service|dbus|xyz.openbmc_project.EntityManager|1
phosphor-ipmi-host.service|dbus|xyz.openbmc_project.Ipmi.Host|0
xyz.openbmc_project.State.BMC.service|dbus|xyz.openbmc_project.State.BMC|0
bmcweb.service|http|https://127.0.0.1/redfish/v1/|0
ceb-gnrd-fan-settings.service|dbus|xyz.openbmc_project.CebGnrd.FanSettings|0
ceb-gnrd-temp-max.service|dbus|xyz.openbmc_project.CebGnrd.TempMax|0
"

log() { echo "$*"; }

sel_add() {
    # SEL record through phosphor-sel-logger, same call as ceb-gnrd-alert-led
    busctl --system call xyz.openbmc_project.Logging.IPMI /xyz/openbmc_project/Logging/IPMI \
        xyz.openbmc_project.Logging.IPMI IpmiSelAdd ssaybq "$1" /xyz/openbmc_project/state/bmc0 \
        3 0x00 0xFF 0xFF true 0x0020 >/dev/null 2>&1 || log "SEL add failed: $1"
}

probe() { # kind target
    case "$1" in
        dbus) busctl --system --timeout="$PING_TIMEOUT" call "$2" / org.freedesktop.DBus.Peer Ping >/dev/null 2>&1 ;;
        http) [ "$(curl -sk -m "$PING_TIMEOUT" -o /dev/null -w '%{http_code}' "$2")" = 200 ] ;;
        *) return 0 ;;
    esac
}

# number of "epoch [name]" lines in a history file that are newer than window seconds
recent() { # file window [name]
    [ -f "$1" ] || { echo 0; return; }
    now=$(date +%s); n=0
    while read -r t name; do
        [ -n "$t" ] || continue
        [ $((now - t)) -le "$2" ] || continue
        [ -z "$3" ] || [ "$name" = "$3" ] || continue
        n=$((n + 1))
    done < "$1"
    echo "$n"
}

remember() { # file name   -- append to a history file and keep it short
    echo "$(date +%s) $2" >> "$1"
    tail -n 20 "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

force_reboot() {
    if [ "$(recent "$STATE/reboots" "$REBOOT_WINDOW")" -ge "$REBOOT_LIMIT" ]; then
        log "reboot wanted ($1) but $REBOOT_LIMIT reboots were already done in the last hour, not rebooting"
        return
    fi
    log "rebooting the BMC: $1"
    remember "$STATE/reboots" reboot
    sel_add "BMC health monitor: rebooting the BMC, $1"
    sync
    reboot -f
}

restart_unit() {
    log "$1 does not answer, restarting it"
    sel_add "BMC health monitor: $1 does not answer, restarted"
    remember "$STATE/restarts" "$1"
    systemctl restart "$1" || log "restart of $1 failed"
}

check_target() { # unit kind target base
    unit=$1; kind=$2; target=$3; base=$4
    counter="$RUN/$unit"
    # only look at units that are running; a unit that is still starting (ipmid waits
    # for the sensors for up to 90 s) or was stopped on purpose is not a hang
    if ! systemctl is-active --quiet "$unit"; then
        rm -f "$counter"
        return
    fi
    if probe "$kind" "$target"; then
        rm -f "$counter"
        return
    fi
    n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter"
    log "$unit probe failed ($n/$FAILS)"
    [ "$n" -ge "$FAILS" ] || return
    rm -f "$counter"
    restart_unit "$unit"
    if [ "$base" = 1 ]; then
        # the object mapper and Entity-Manager are the base of everything: still not
        # answering after a restart means reboot the BMC
        sleep 20
        probe "$kind" "$target" || force_reboot "$unit still not answering after a restart"
    elif [ "$(recent "$STATE/restarts" "$RESTART_WINDOW" "$unit")" -ge "$RESTART_LIMIT" ]; then
        force_reboot "$unit was restarted $RESTART_LIMIT times in $((RESTART_WINDOW / 60)) minutes"
    fi
}

log "started: interval ${INTERVAL}s, ${FAILS} failures, first check after ${START_DELAY}s"
sleep "$START_DELAY"

while true; do
    for line in $TARGETS; do
        IFS='|' read -r unit kind target base <<EOF
$line
EOF
        [ -n "$unit" ] || continue
        check_target "$unit" "$kind" "$target" "$base"
    done
    sleep "$INTERVAL"
done
