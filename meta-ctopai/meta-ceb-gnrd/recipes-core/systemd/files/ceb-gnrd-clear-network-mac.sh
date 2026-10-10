#!/bin/sh
# Remove legacy link-MAC overrides before systemd-networkd reads board configs.
# Preserve IP/DHCP/DNS settings and [Neighbor] MACAddress entries. Repair old
# NC-SI activation policies before networkd can raise the host-powered link.
set -eu

pending=
trap 'if [ -n "$pending" ]; then rm -f "$pending"; fi' EXIT
trap 'exit 1' HUP INT TERM

for config in /etc/systemd/network/00-bmc-eth0.network \
              /etc/systemd/network/00-bmc-eth1.network \
              /etc/systemd/network/10-bmc-eth1-ncsi.network; do
    [ -f "$config" ] || continue
    ncsi=0
    case "$config" in
        *eth1.network|*eth1-ncsi.network) ncsi=1 ;;
    esac
    pending=$(mktemp "${config}.XXXXXX")
    cp -p "$config" "$pending"
    awk -v ncsi="$ncsi" '
        function finish_link() {
            if (ncsi && link && !policy) print "ActivationPolicy=manual"
        }
        /^[ \t]*\[/ {
            finish_link()
            link = ($0 ~ /^[ \t]*\[Link\][ \t]*$/)
            policy = 0
            if (link) seen_link = 1
        }
        link && /^[ \t]*MACAddress[ \t]*=/ { next }
        ncsi && link && /^[ \t]*ActivationPolicy[ \t]*=/ {
            policy = 1
            # Preserve an explicit administrative disable.
            if ($0 ~ /=[ \t]*(down|always-down)[ \t]*$/) print
            else print "ActivationPolicy=manual"
            next
        }
        { print }
        END {
            finish_link()
            if (ncsi && !seen_link) print "\n[Link]\nActivationPolicy=manual"
        }
    ' "$config" > "$pending"
    if cmp -s "$pending" "$config"; then
        rm -f "$pending"
        pending=
        continue
    fi
    mv -f "$pending" "$config"
    pending=
    echo "CEB-GNRD: repaired boot MAC / NC-SI activation policy in $config"
done
