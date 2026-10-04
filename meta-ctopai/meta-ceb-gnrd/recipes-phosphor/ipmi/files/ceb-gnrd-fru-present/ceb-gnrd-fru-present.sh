#!/bin/sh
# Mark the board FRU as present in the inventory at every boot.
#
# ipmid answers "Get FRU Inventory Area Info" - the first step of "ipmitool fru
# print" and "ipmitool fru write" - only when the inventory object of the FRU has
# xyz.openbmc_project.Inventory.Item Present = true.  ipmi-fru-parser sets it only
# after it has parsed FRU data, so a blank EEPROM could never be written through
# IPMI.  The FRU is a fixed part of the board (an EEPROM with no presence detect),
# so it is always present; the area is padded by ipmid so ipmitool can write a
# whole FRU image into it.

set -u
BUS=xyz.openbmc_project.Inventory.Manager
ROOT=/xyz/openbmc_project/inventory
ITEM=xyz.openbmc_project.Inventory.Item

i=0
while [ "$i" -lt 120 ]
do
    if busctl --system call "$BUS" "$ROOT" "$BUS" Notify 'a{oa{sa{sv}}}' 3 \
        /system 1 "$ITEM" 1 Present b true \
        /system/chassis 1 "$ITEM" 1 Present b true \
        /system/chassis/motherboard 1 "$ITEM" 1 Present b true \
        >/dev/null 2>&1
    then
        echo "FRU 0 marked present in the inventory"
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done
echo "inventory manager did not accept the FRU presence" >&2
exit 1
