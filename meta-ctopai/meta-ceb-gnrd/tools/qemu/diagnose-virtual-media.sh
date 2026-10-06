#!/bin/sh
# Read-only BMC diagnostics; run immediately after an unsuccessful mount.
# Does not mount/unmount media, restart services or read the image contents.

echo '=== BMC uptime and proxy processes ==='
uptime
ps | grep -E 'bmcweb|nbd-proxy|nbd-client' | grep -v grep

echo '=== bmcweb and virtual media journal ==='
journalctl -b -u bmcweb.service --no-pager -n 150

echo '=== NBD backing devices ==='
for dev in /sys/block/nbd0 /sys/block/nbd1; do
    [ -d "$dev" ] || continue
    echo "$dev"
    for attr in size pid; do
        if [ -r "$dev/$attr" ]; then
            printf '%s=' "$attr"
            cat "$dev/$attr"
        else
            echo "$attr=absent"
        fi
    done
done

echo '=== USB gadget owner and controllers ==='
cat /run/nbd-proxy-gadget.owner 2>/dev/null || true
ls /sys/class/udc
for gadget in /sys/kernel/config/usb_gadget/*; do
    [ -d "$gadget" ] || continue
    echo "GADGET=$gadget"
    printf 'UDC='
    cat "$gadget/UDC"
    for lun in "$gadget"/functions/mass_storage.*/lun.*; do
        [ -d "$lun" ] || continue
        echo "LUN=$lun"
        for attr in file ro removable cdrom; do
            printf '%s=' "$attr"
            cat "$lun/$attr"
        done
    done
done

echo '=== Recent kernel messages ==='
dmesg | tail -n 100
