#!/bin/sh
# Read-only diagnostics. Run on the QEMU Linux host or in the BMC serial shell.
# No service restart, network change, login, or credential collection.
set -u

section() { printf '\n===== %s =====\n' "$1"; }
run() {
    printf '\n$'; for arg do printf ' %s' "$arg"; done; printf '\n'
    "$@" 2>&1 || true
}
http_probe() {
    if command -v curl >/dev/null 2>&1; then
        run curl --noproxy '*' -k -i --connect-timeout 3 --max-time 10 "$1"
    else
        printf 'curl is not installed; use the listener and service output below.\n'
    fi
}

case "${1:-}" in
host)
    section 'QEMU host: clock and processes'
    run date -u
    run ps -ef
    section 'Host listeners (expected 127.0.0.1:8443 and :2222)'
    if command -v ss >/dev/null 2>&1; then
        run ss -lntp
    else
        run netstat -lntp
    fi
    section 'Forwarded BMC Redfish (no login; HTTP 200 or 401 proves an HTTP response)'
    http_probe https://127.0.0.1:8443/redfish/v1/
    section 'Forwarded web root'
    http_probe https://127.0.0.1:8443/
    section 'Recent QEMU diagnostics'
    run tail -n 80 "${STATE:-$HOME/qemu-ceb-gnrd}/qemu.log"
    ;;
bmc)
    section 'BMC clock, uptime and network'
    run date -u
    run uptime
    run ip addr show
    run ip route show
    run systemctl status systemd-networkd.service --no-pager -l -n 20
    section 'bmcweb service and socket'
    run systemctl status bmcweb.service bmcweb.socket --no-pager -l -n 40
    run systemctl show bmcweb.service -p ActiveState -p SubState -p Result \
        -p ExecMainStatus -p NRestarts -p Restart -p OnFailure
    run systemctl cat bmcweb.service bmcweb.socket
    section 'BMC listeners (443 may be owned by systemd socket activation)'
    if command -v ss >/dev/null 2>&1; then
        run ss -lntp
    elif command -v netstat >/dev/null 2>&1; then
        run netstat -lntp
    else
        run cat /proc/net/tcp /proc/net/tcp6
    fi
    section 'Local Redfish and web root'
    http_probe https://127.0.0.1/redfish/v1/
    http_probe https://127.0.0.1/
    section 'bmcweb current-boot journal'
    run journalctl -b -u bmcweb.service -u bmcweb.socket --no-pager -n 100
    section 'Failed services and resource pressure'
    run systemctl --failed --no-pager
    run df -h
    run df -i
    run cat /proc/meminfo
    if command -v coredumpctl >/dev/null 2>&1; then
        run coredumpctl list bmcweb --no-pager
    fi
    section 'Kernel tail (includes OOM and Ethernet faults if still in ring buffer)'
    run dmesg | tail -n 100
    ;;
*)
    printf 'Usage: sh diagnose-web.sh host|bmc\n'
    printf '  host: run on the Linux machine running QEMU\n'
    printf '  bmc:  run inside the BMC, using its serial shell\n'
    exit 2
    ;;
esac
