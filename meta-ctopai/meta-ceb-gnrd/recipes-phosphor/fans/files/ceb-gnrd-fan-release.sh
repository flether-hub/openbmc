#!/bin/sh

set -eu

line="BMC_FAN_BMC_OVERRIDE_N"
location=$(gpiofind "$line")
set -f
set -- $location
if [ "$#" -ne 2 ]; then
    echo "Unexpected gpiofind result for $line: $location" >&2
    exit 1
fi

# Deassert BMC ownership so the CPLD regains fan PWM control.
gpioset --mode=exit "$1" "$2=0"
