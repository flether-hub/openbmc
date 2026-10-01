#!/bin/sh

set -eu

LED_TRIGGER=/sys/class/leds/bmc-heartbeat/trigger
ESPI_DRIVER=/sys/bus/platform/drivers/aspeed-espi-peripheral

while :; do
    if [ -d "$ESPI_DRIVER" ]; then
        for device in "$ESPI_DRIVER"/*; do
            # Platform devices bound to this driver have an OF node. Ignore
            # the driver's optional module symlink.
            if [ -e "$device/of_node" ] && [ -w "$LED_TRIGGER" ]; then
                printf '%s\n' heartbeat > "$LED_TRIGGER"
                exit 0
            fi
        done
    fi

    sleep 1
done
