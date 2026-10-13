#!/bin/sh
# Log an unexpected BMC reset to the SEL.
#
# aspeed_wdt reports in /sys/class/watchdog/watchdog0/bootstatus whether the last
# reset came from the watchdog (WDIOF_CARDRESET, 0x20).  Every restart the kernel
# does goes through the watchdog, including a normal "reboot", so the status alone
# cannot tell a hang from a clean reboot.  The service therefore leaves a marker
# file when it is stopped at shutdown ("stop"); at the next boot ("start") a
# watchdog reset without the marker is an unexpected reset: a hang of systemd or
# the kernel, or a kernel panic (a "reboot -f" counts too).
#
#   ceb-gnrd-wdt-reset-log start|stop

STATE=/var/lib/ceb-gnrd
MARK=$STATE/clean-shutdown
BOOT_STATE=/run/ceb-gnrd
BOOT_CLEAN=$BOOT_STATE/previous-clean-shutdown
STATUS=/sys/class/watchdog/watchdog0/bootstatus
CARDRESET=32

sel_add() {
    # IPMI 2.0 Table 42-3: Watchdog 2 (0x23), hard reset (offset 0x01).
    # No board SDR exists for this event; use 0xff without inventing a number.
    i=0
    while [ "$i" -lt 10 ]; do
        busctl --system call xyz.openbmc_project.Logging.IPMI /xyz/openbmc_project/Logging/IPMI \
            xyz.openbmc_project.Logging.IPMI IpmiSelAddPlatform syyyaybq \
            "$1" 0x23 0xff 0x6f 3 0x01 0xFF 0xFF true 0x0020 >/dev/null 2>&1 && return 0
        i=$((i + 1)); sleep 3
    done
    echo "SEL add failed: $1"
    return 1
}

case "$1" in
    stop)
        mkdir -p "$STATE"
        : > "$MARK"
        sync
        ;;
    start)
        if [ -r "$BOOT_CLEAN" ]; then
            # A service restart is not another BMC boot. Keep the original
            # decision and consume any marker written by its preceding stop.
            rm -f "$MARK"
            echo "BMC reset cause already recorded for this boot; keeping the original decision"
            exit 0
        fi
        status=0
        [ -r "$STATUS" ] && status=$(cat "$STATUS")
        clean=0
        [ -e "$MARK" ] && clean=1
        # Preserve this boot's decision for phosphor-bmc-state-manager before
        # consuming the persistent marker. /run is cleared on the next boot.
        if mkdir -p "$BOOT_STATE" &&
            printf '%s\n' "$clean" > "$BOOT_CLEAN.tmp" &&
            mv -f "$BOOT_CLEAN.tmp" "$BOOT_CLEAN"; then
            :
        else
            echo "Failed to publish the previous clean-shutdown state" >&2
        fi
        rm -f "$MARK"
        if [ $((status & CARDRESET)) -ne 0 ] && [ "$clean" = 0 ]; then
            echo "BMC was restarted by the hardware watchdog without a clean shutdown (bootstatus=$status)"
            sel_add "BMC unexpected reset: hardware watchdog (hang, panic or forced reboot)"
        else
            echo "BMC start: bootstatus=$status, clean shutdown marker=$clean"
        fi
        ;;
    *)
        echo "usage: $0 start|stop" >&2
        exit 2
        ;;
esac
