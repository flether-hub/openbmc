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

# Read the entire EEPROM successfully before making the blank decision.
# An erased header is not proof that the remaining FRU data is empty.
snapshot=$(mktemp /tmp/ceb-gnrd-fru.XXXXXX) || exit 1
trap 'rm -f "$snapshot"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
if ! cat "$EEPROM" > "$snapshot" || [ ! -s "$snapshot" ]; then
    echo "Unable to read the entire FRU EEPROM; left unchanged" >&2
    exit 1
fi
# BusyBox od emits an offset, hex words and a final offset-only line.
# Reject every non-FFFF word rather than inspecting just the common header.
hex=$(od -v -x "$snapshot") || {
    echo "Unable to inspect FRU EEPROM contents; left unchanged" >&2
    exit 1
}
if ! printf '%s\n' "$hex" | awk '
    NF > 1 { words += NF - 1; for (i = 2; i <= NF; i++) if ($i != "ffff") bad = 1 }
    END { exit (bad || !words) ? 1 : 0 }'; then
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
