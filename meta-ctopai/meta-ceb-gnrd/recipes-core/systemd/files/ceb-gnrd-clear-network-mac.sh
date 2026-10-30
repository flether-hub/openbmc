#!/bin/sh
# Remove legacy link-MAC overrides before systemd-networkd reads board configs.
# Preserve IP/DHCP/DNS settings and [Neighbor] MACAddress entries. Repair old
# NC-SI activation policies before networkd can raise the host-powered link.
# Migrate managed physical NIC matches to the board's verified udev ID_PATH.
set -eu

candidate=
pending=
cleanup() {
    if [ -n "$candidate" ]; then rm -f "$candidate"; fi
    if [ -n "$pending" ]; then rm -f "$pending"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for config in /etc/systemd/network/00-bmc-eth0.network \
              /etc/systemd/network/00-bmc-eth1.network \
              /etc/systemd/network/10-bmc-eth1-ncsi.network; do
    [ -f "$config" ] || continue
    ncsi=0
    case "$config" in
        *eth0.network) hardware_path=platform-1e680000.ethernet ;;
        *eth1.network|*eth1-ncsi.network)
            ncsi=1
            hardware_path=platform-1e670000.ethernet
            ;;
    esac
    # /run is RAM-backed: an already migrated configuration must not need
    # writable space on rwfs just to start or restart the network service.
    if [ -z "$candidate" ]; then
        candidate=$(mktemp /run/ceb-gnrd-network-migration.XXXXXX)
    fi
    awk -v ncsi="$ncsi" -v hardware_path="$hardware_path" '
        function finish_match() {
            if (match_section) print "Path=" hardware_path
        }
        function finish_link() {
            if (ncsi && link) {
                if (!policy) print "ActivationPolicy=manual"
                print "RequiredForOnline=" (disabled ? "no" : "routable")
            }
        }
        /^[ \t]*\[/ {
            finish_match()
            finish_link()
            match_section = ($0 ~ /^[ \t]*\[Match\][ \t]*$/)
            if (match_section) seen_match = 1
            link = ($0 ~ /^[ \t]*\[Link\][ \t]*$/)
            policy = 0
            disabled = 0
            if (link) seen_link = 1
        }
        match_section && /^[ \t]*(Name|Path)[ \t]*=/ { next }
        link && /^[ \t]*MACAddress[ \t]*=/ { next }
        ncsi && link && /^[ \t]*RequiredForOnline[ \t]*=/ { next }
        ncsi && link && /^[ \t]*ActivationPolicy[ \t]*=/ {
            policy = 1
            # Preserve an explicit administrative disable.
            if ($0 ~ /=[ \t]*(down|always-down)[ \t]*$/) { disabled = 1; print }
            else print "ActivationPolicy=manual"
            next
        }
        { print }
        END {
            finish_match()
            finish_link()
            if (!seen_match) print "\n[Match]\nPath=" hardware_path
            if (ncsi && !seen_link) print "\n[Link]\nActivationPolicy=manual\nRequiredForOnline=routable"
        }
    ' "$config" > "$candidate"
    if cmp -s "$candidate" "$config"; then
        continue
    fi
    # A required migration must succeed before networkd starts, especially
    # when an old NC-SI policy would raise the interface before host POST.
    # Stage beside the destination for an atomic rename and preserve its
    # ownership and permissions. A failed copy/write leaves it untouched.
    pending=$(mktemp "${config}.XXXXXX")
    cp -p "$config" "$pending"
    cat "$candidate" > "$pending"
    mv -f "$pending" "$config"
    pending=
    echo "CEB-GNRD: repaired hardware match / boot MAC / NC-SI activation policy in $config"
done
