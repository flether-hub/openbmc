#!/bin/sh
# Limit the automatic BMC reboots after the BMC entered Quiesced.
#
# phosphor-state-manager (option auto-reboot-on-bmc-quiesce) runs
# phosphor-bmc-quiesce-reboot.service, which reboots the BMC every time a critical
# service fails for good.  Upstream has no limit, so a permanent fault reboots the
# BMC forever.  This script is the ExecCondition of that unit:
#
#   check   allow the reboot and count it; refuse (exit 1, the unit is skipped and
#           the BMC stays in Quiesced) once LIMIT reboots were done in a row
#   clear   forget the count; the timer runs it 15 minutes after boot, so only
#           reboots that follow each other quickly are counted
#
# The count is kept in the read-write flash and survives the reboot itself.

STATE=/var/lib/ceb-gnrd
FILE=$STATE/quiesce-reboots
LIMIT=1

sel_add() {
    # Management Subsystem Health: controller access degraded (42-3, 0x28/1).
    # No SDR object is claimed for this software health event (sensor 0xff).
    busctl --system call xyz.openbmc_project.Logging.IPMI /xyz/openbmc_project/Logging/IPMI \
        xyz.openbmc_project.Logging.IPMI IpmiSelAddPlatform syyyaybq \
        "$1" 0x28 0xff 0x6f 3 0x01 0xFF 0xFF true 0x0020 >/dev/null 2>&1 || true
}

case "$1" in
    check)
        n=$(cat "$FILE" 2>/dev/null || echo 0)
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if [ "$n" -ge "$LIMIT" ]; then
            echo "automatic BMC reboot limit ($LIMIT) reached, staying in Quiesced"
            sel_add "BMC quiesced: automatic reboot limit ($LIMIT) reached, not rebooting again"
            exit 1
        fi
        mkdir -p "$STATE"
        echo $((n + 1)) > "$FILE"
        sync
        echo "automatic BMC reboot $((n + 1)) of $LIMIT"
        sel_add "BMC quiesced: automatic reboot $((n + 1)) of $LIMIT"
        exit 0
        ;;
    clear)
        rm -f "$FILE"
        echo "automatic reboot count cleared"
        ;;
    *)
        echo "usage: $0 check|clear" >&2
        exit 2
        ;;
esac
