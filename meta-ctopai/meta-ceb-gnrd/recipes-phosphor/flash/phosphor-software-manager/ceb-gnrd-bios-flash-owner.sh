#!/bin/bash
# Independent cgroup: an exited/timed-out BIOS updater cannot kill this holder.
# The marker is removed only after SPI detach and verified GPIO hand-back.
set -euo pipefail
[[ -d /run/ceb-gnrd-bios-flash-held ]] || exit 1
mkdir -p /run/lock
exec 6>/run/lock/ceb-gnrd-reboot-guard.lock
flock -s 6
/usr/bin/obmc-flash-bmc rebootguardenable

holder=
cleanup() {
    if [[ -n "$holder" ]]; then
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 0' TERM INT
read -r chip line <<< "$(gpiofind BMC_BIOS_FLASH_SELECT)"
[[ -n "${chip:-}" && -n "${line:-}" ]] || exit 1
gpioset --mode=signal "$chip" "${line}=1" &
holder=$!
sleep 1
kill -0 "$holder"
systemd-notify --ready --status="BMC holds BIOS flash; explicit detach/release required"
wait "$holder" || true
# A holder that exits without an explicit service stop must be restarted.
exit 1
