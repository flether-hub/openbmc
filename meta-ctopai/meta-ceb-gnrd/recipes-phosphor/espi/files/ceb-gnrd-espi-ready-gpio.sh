#!/bin/sh

set -eu

ready=0
while [ "${ready}" -eq 0 ]; do
    for node in ${CEB_GNRD_ESPI_READY_SYSFS}; do
        if [ -e "${node}" ]; then
            ready=1
            break
        fi
    done

    if [ "${ready}" -eq 0 ]; then
        sleep 1
    fi
done

# Keep the GPIO request alive so the output remains asserted.  systemd will
# terminate gpioset on service stop, releasing the line cleanly.
exec gpioset --mode=signal \
    "${CEB_GNRD_ESPI_READY_GPIOCHIP}" \
    "${CEB_GNRD_ESPI_READY_GPIOLINE}=1"
