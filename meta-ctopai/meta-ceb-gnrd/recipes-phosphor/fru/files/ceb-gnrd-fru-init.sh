#!/bin/sh
# Give a blank board FRU EEPROM a default (placeholder) FRU image.
#
# ipmitool fru print/write go through fru-device (ipmid's dynamic-sensors
# option), and fru-device only registers EEPROMs that hold a valid FRU, so a
# blank EEPROM (all 0xFF) could never be written with "ipmitool fru write".  With
# the default image in place the FRU is found as FRU 0 (chassis type 0x17) and
# ipmitool can replace it with the real data.  An EEPROM that already holds data,
# valid or not, is never touched.

EEPROM=/sys/bus/i2c/devices/10-0050/eeprom
DEFAULT=/usr/share/ceb-gnrd/default-fru.bin
BLANK=ffffffffffffffffffffffffffffffff

i=0
while [ ! -r "$EEPROM" ] && [ "$i" -lt 30 ]
do
    i=$((i + 1))
    sleep 1
done
if [ ! -r "$EEPROM" ]; then
    echo "FRU EEPROM $EEPROM not found" >&2
    exit 1
fi

# BusyBox od has no -A/-t/-N: first 16 bytes as 8 hex words
first=$(dd if="$EEPROM" bs=16 count=1 2>/dev/null | od -v -x | head -n 1)
first=$(echo "${first#* }" | tr -d ' ')
if [ "$first" != "$BLANK" ]; then
    echo "FRU EEPROM is not blank, left unchanged"
    exit 0
fi

if cat "$DEFAULT" > "$EEPROM"; then
    echo "blank FRU EEPROM: wrote the default FRU image"
else
    echo "writing the default FRU image failed" >&2
    exit 1
fi
# fru-device may already have scanned: have it look again (best effort)
busctl --system call xyz.openbmc_project.FruDevice /xyz/openbmc_project/FruDevice \
    xyz.openbmc_project.FruDeviceManager ReScan >/dev/null 2>&1 || true
exit 0
