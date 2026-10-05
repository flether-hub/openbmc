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

# PWM file of fan channel N (1..6): pwmN next to the tach inputs (older
# aspeed-pwm-tacho driver), or pwm1 of the pwm-fan(N-1) device (aspeed-g6-pwm-tach
# registers its PWMs only as a pwmchip; the DTS adds pwm-fan0..5 for them).
pwm_file() {
    if [ -e "$1/pwm$2" ]; then
        echo "$1/pwm$2"
        return
    fi
    for h in /sys/class/hwmon/hwmon*; do
        if [ "$(basename "$(readlink -f "$h/device")")" = "pwm-fan$(($2 - 1))" ] &&
            [ -e "$h/pwm1" ]; then
            echo "$h/pwm1"
            return
        fi
    done
}

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
            tach="$hwmon/fan${channel}_input"
            pwm=$(pwm_file "$hwmon" "$channel")
            if [ -z "$pwm" ] || [ ! -r "$pwm" ] || [ ! -w "$pwm" ] || [ ! -r "$tach" ]; then
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
#
# Fan ownership must not survive a BMC reset (watchdog or user triggered): while the
# BMC restarts it cannot run fan control, so the CPLD has to take the fans back.
# Every line requested from user space is made reset tolerant by the kernel (the
# AST2600 then keeps its direction and level across a watchdog reset), so clear the
# reset tolerance bit of this line again once it is held: a reset then returns the
# pin to an input.  If that fails, do not take ownership at all.
chip=$1
line_no=$2

case "$chip" in
    gpiochip0) ;;
    *)
        echo "$line is on $chip, expected gpiochip0 (1e780000); leaving control with CPLD" >&2
        exit 1
        ;;
esac

# Reset tolerance register of each 32 line bank of the 1e780000 GPIO controller
# (A-D, E-H, I-L, M-P, Q-T, U-X, Y-AB, AC)
case $((line_no / 32)) in
    0) tol=0x1e78001c ;;
    1) tol=0x1e78003c ;;
    2) tol=0x1e7800ac ;;
    3) tol=0x1e7800fc ;;
    4) tol=0x1e78012c ;;
    5) tol=0x1e78015c ;;
    6) tol=0x1e78018c ;;
    *) tol=0x1e7801bc ;;
esac
mask=$((1 << (line_no % 32)))

if command -v devmem >/dev/null 2>&1; then
    devmem=devmem
else
    devmem="busybox devmem"
fi

gpioset --mode=signal "$chip" "$line_no=1" &
holder=$!
trap 'kill "$holder" 2>/dev/null' TERM INT

# give gpioset a moment to request the line (that is what sets the tolerance bit)
sleep 1
if ! kill -0 "$holder" 2>/dev/null; then
    echo "gpioset could not hold $line" >&2
    exit 1
fi

reg=$($devmem "$tol" 32 2>/dev/null) || reg=""
if [ -z "$reg" ] || ! $devmem "$tol" 32 $((reg & ~mask)) 2>/dev/null ||
    [ $(($($devmem "$tol" 32 2>/dev/null) & mask)) -ne 0 ]; then
    echo "Cannot clear the reset tolerance of $line ($tol, devmem); leaving control with CPLD" >&2
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    exit 1
fi
echo "$line: BMC owns the fans, reset tolerance cleared (a BMC reset returns them to the CPLD)"

wait "$holder"
