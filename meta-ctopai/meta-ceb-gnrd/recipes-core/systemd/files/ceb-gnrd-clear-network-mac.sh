#!/bin/sh
# Remove legacy link-MAC overrides before systemd-networkd reads board configs.
# Preserve IP/DHCP/DNS settings and [Neighbor] MACAddress entries.
set -eu

pending=
trap 'if [ -n "$pending" ]; then rm -f "$pending"; fi' EXIT
trap 'exit 1' HUP INT TERM

for config in /etc/systemd/network/00-bmc-eth0.network \
              /etc/systemd/network/00-bmc-eth1.network \
              /etc/systemd/network/10-bmc-eth1-ncsi.network; do
    [ -f "$config" ] || continue
    if ! awk '
        /^[ \t]*\[/ { link = ($0 ~ /^[ \t]*\[Link\][ \t]*$/) }
        link && /^[ \t]*MACAddress[ \t]*=/ { found = 1 }
        END { exit !found }
    ' "$config"; then
        continue
    fi

    pending=$(mktemp "${config}.XXXXXX")
    cp -p "$config" "$pending"
    awk '
        /^[ \t]*\[/ { link = ($0 ~ /^[ \t]*\[Link\][ \t]*$/) }
        link && /^[ \t]*MACAddress[ \t]*=/ { next }
        { print }
    ' "$config" > "$pending"
    mv -f "$pending" "$config"
    pending=
    echo "CEB-GNRD: removed saved link MAC from $config; using boot-provided address"
done
