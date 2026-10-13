#!/bin/sh
# Empty discovery is expected before Entity-Manager publishes its sensors.
# Wait for a stable count, preserving diagnostics for real mapper failures.
uptime_seconds() {
    read -r uptime_value unused_value < /proc/uptime
    printf '%s\n' "${uptime_value%%.*}"
}

deadline=$(( $(uptime_seconds) + 90 ))
last=-1
same=0
last_error=""
while [ "$(uptime_seconds)" -lt "$deadline" ]; do
    # busctl can send errors directly to the journal inside a systemd unit.
    # Route its diagnostics to captured stderr, then classify them below.
    if reply=$(SYSTEMD_LOG_TARGET=console busctl --system --timeout=2 call xyz.openbmc_project.ObjectMapper \
        /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper \
        GetSubTreePaths sias /xyz/openbmc_project/sensors 0 1 \
        xyz.openbmc_project.Sensor.Value 2>&1); then
        # GetSubTreePaths returns: as <count> <quoted paths...>
        set -f
        set -- $reply
        if [ "$#" -ge 2 ] && [ "$1" = as ]; then
            count=$2
            case "$count" in
                ''|*[!0-9]*) count=0 ;;
            esac
        else
            count=0
        fi
        last_error=""
    else
        count=0
        case "$reply" in
            *'The resource is not found.'*|*'xyz.openbmc_project.Common.Error.ResourceNotFound'*)
                # No Sensor.Value objects yet; the next startup poll retries.
                ;;
            *)
                if [ "$reply" != "$last_error" ]; then
                    printf 'Sensor discovery query failed: %s\n' "$reply" >&2
                    last_error=$reply
                fi
                ;;
        esac
    fi
    if [ "$count" -ne 0 ] && [ "$count" = "$last" ]; then
        same=$((same + 1))
    else
        same=0
    fi
    last=$count
    [ "$same" -lt 8 ] || exit 0
    sleep 1
done
# Discovery is best effort; ipmid also receives later sensor additions.
exit 0
