#!/bin/sh
# Called synchronously by omfile after closing its file. Do not send HUP:
# omfile reopens the current filename when this command returns.
set -eu
case "${1:-}" in
    /var/log/bmc-system.log) copies=5 ;;
    /var/log/ipmi_sel|/var/log/redfish) copies=1 ;;
    *) exit 1 ;;
esac
file=$1
# Only these three regular files and their fixed archive names are managed.
for suffix in '' .1 .2 .3 .4 .5; do
    [ ! -L "$file$suffix" ] || exit 1
    [ ! -e "$file$suffix" ] || [ -f "$file$suffix" ] || exit 1
done
rm -f -- "$file.$copies"
i=$copies
while [ "$i" -gt 1 ]; do
    previous=$((i - 1))
    if [ -f "$file.$previous" ]; then
        mv -- "$file.$previous" "$file.$i"
    fi
    i=$previous
done
if [ -f "$file" ]; then
    mv -- "$file" "$file.1"
fi
