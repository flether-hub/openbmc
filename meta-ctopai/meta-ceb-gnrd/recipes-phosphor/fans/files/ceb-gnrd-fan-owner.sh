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

# Do not switch the CPLD mux until all six BMC PWM and tach channels exist.
ready=0
attempt=0
while [ "$attempt" -lt 60 ]; do
    fan_control_ready=0
    if busctl --system tree xyz.openbmc_project.State.FanCtrl \
        /xyz/openbmc_project/settings/fanctrl --no-pager 2>/dev/null |
        grep -Eq '/zone[0-9]+$'; then
        fan_control_ready=1
    fi

    for hwmon in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue
        channels_ready=1
        channel=1
        while [ "$channel" -le 6 ]; do
            pwm="$hwmon/pwm$channel"
            tach="$hwmon/fan${channel}_input"
            if [ ! -r "$pwm" ] || [ ! -w "$pwm" ] || [ ! -r "$tach" ]; then
                channels_ready=0
                break
            fi
            channel=$((channel + 1))
        done
        if [ "$channels_ready" -eq 1 ] && [ "$fan_control_ready" -eq 1 ]; then
            ready=1
            break
        fi
    done
    [ "$ready" -eq 1 ] && break
    attempt=$((attempt + 1))
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    echo "Fan-control zone and six PWM/TACH channels did not become ready; leaving control with CPLD" >&2
    exit 1
fi

# The board GPIO table specifies high as BMC ownership; low leaves control with
# the CPLD. Keep the line requested for as long as fan control is active.
exec gpioset --mode=signal "$1" "$2=1"
