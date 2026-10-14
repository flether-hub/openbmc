#!/bin/sh
# Wait for mapper discovery, not just the inventory service's D-Bus name.
# Bounded and read-only; never create temporary files in a service sandbox.
case "${1:-}" in
    '') optional=0 ;;
    --optional) optional=1 ;;
    *) echo "Unknown inventory wait option: $1" >&2; exit 2 ;;
esac
count=0
while [ "$count" -lt 20 ]; do
    paths=$(busctl --system --timeout=2 call xyz.openbmc_project.ObjectMapper \
        /xyz/openbmc_project/object_mapper xyz.openbmc_project.ObjectMapper \
        GetSubTreePaths sias / 0 1 xyz.openbmc_project.Inventory.Item.Bmc 2>/dev/null) || paths=""
    case "$paths" in
        *'"/xyz/openbmc_project/inventory/system/chassis/motherboard/bmc"'*) exit 0 ;;
    esac
    count=$((count + 1))
    sleep 1
done
echo "CEB-GNRD: BMC inventory mapper discovery timed out" >&2
if [ "$optional" = 1 ]; then
    echo "CEB-GNRD: starting firmware updater without BMC inventory associations; upgrade recovery remains available" >&2
    exit 0
fi
exit 1
