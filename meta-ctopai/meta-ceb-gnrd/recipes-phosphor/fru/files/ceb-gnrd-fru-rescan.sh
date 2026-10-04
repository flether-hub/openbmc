#!/bin/sh
# Make "ipmitool fru write" show up at once.
#
# ipmid writes a FRU through fru-device's WriteFru method.  fru-device is meant to
# rescan 1 s afterwards, but on this board "ipmitool fru print" kept returning
# the old data until a rescan was requested by hand (ReScan).  Watch the bus for
# WriteFru calls and ask for that rescan 3 s after each one.

busctl --system --json=short \
    --match="type='method_call',interface='xyz.openbmc_project.FruDeviceManager',member='WriteFru'" \
    monitor |
while read -r _
do
    (
        sleep 3
        busctl --system call xyz.openbmc_project.FruDevice /xyz/openbmc_project/FruDevice \
            xyz.openbmc_project.FruDeviceManager ReScan >/dev/null 2>&1
    ) &
done
exit 1
