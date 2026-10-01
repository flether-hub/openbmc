#!/bin/sh
# Detect presses of the chassis power button and record them in the IPMI SEL
# and the journal.  This is detection only: nothing is driven on the CPU power
# button output and the host power state is never changed from here.
#
# The button is active low (BMC_POWER_BUTTON_INPUT, GPIOM2): a press is a
# falling edge.  x86-power-control is configured without a PowerButton entry,
# so this service is the only user of the line.

LINE="BMC_POWER_BUTTON_INPUT"
DEBOUNCE_SECONDS=1

log() {
    echo "$*"
    logger -t ceb-gnrd-power-button "$*" 2>/dev/null || true
}

record_press() {
    # Redfish event log message (journal).
    printf 'MESSAGE=Chassis power button pressed\nPRIORITY=6\nREDFISH_MESSAGE_ID=OpenBMC.0.1.PowerButtonPressed\n' |
        logger --journald 2>/dev/null || true

    # IPMI SEL record (also visible in the web event log).
    attempt=0
    while [ "$attempt" -lt 3 ]
    do
        if busctl call xyz.openbmc_project.Logging.IPMI \
            /xyz/openbmc_project/Logging/IPMI \
            xyz.openbmc_project.Logging.IPMI IpmiSelAdd ssaybq \
            'Chassis Power Button Pressed' \
            '/xyz/openbmc_project/state/chassis0' \
            3 0x00 0xff 0xff true 0x0020 >/dev/null 2>&1
        then
            log "power button pressed: SEL entry added"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    log "WARNING: power button pressed but the SEL entry could not be added"
    return 1
}

log "monitoring $LINE (falling edge = pressed)"
while :
do
    location=$(gpiofind "$LINE" 2>/dev/null)
    set -f
    set -- $location
    set +f
    if [ "$#" -ne 2 ]
    then
        log "WARNING: GPIO line $LINE not found, retrying"
        sleep 5
        continue
    fi

    last=0
    gpiomon --falling-edge --format='%e' "$1" "$2" 2>/dev/null |
    while read -r _
    do
        now=$(date +%s)
        if [ $((now - last)) -ge "$DEBOUNCE_SECONDS" ]
        then
            last=$now
            record_press
        fi
    done

    log "WARNING: GPIO edge monitor stopped, restarting"
    sleep 1
done
