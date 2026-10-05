#!/bin/sh
# Read-only firmware diagnostics for the simulator or a real board.
# GPIO inputs/outputs are not requested; no LED, fan, or power state is changed.
section() { printf '\n===== %s =====\n' "$1"; }
run() {
    printf '\n$'; for arg do printf ' %s' "$arg"; done; printf '\n'
    "$@" 2>&1 || true
}

section 'Boot and failed units'
run date -u
run uptime
run systemctl --failed --no-pager
section 'UID button, handler and LED units'
run systemctl list-units --all --no-pager '*button*' '*led*'
run busctl --system tree xyz.openbmc_project.Chassis.Buttons --no-pager
run busctl --system tree xyz.openbmc_project.LED.GroupManager --no-pager
run busctl --system get-property xyz.openbmc_project.LED.GroupManager \
    /xyz/openbmc_project/led/groups/enclosure_identify xyz.openbmc_project.Led.Group Asserted
run gpioinfo
run cat /sys/kernel/debug/gpio
for led in /sys/class/leds/*; do
    [ -d "$led" ] || continue
    printf '\nLED: %s\n' "$led"
    run cat "$led/brightness" "$led/trigger"
done
section 'Fan ownership, control and sensors'
run systemctl status ceb-gnrd-fan-owner.service phosphor-pid-control.service \
    ceb-gnrd-fan-settings.service ceb-gnrd-temp-max.service --no-pager -l -n 30
run journalctl -b -u ceb-gnrd-fan-owner.service -u phosphor-pid-control.service \
    -u ceb-gnrd-fan-settings.service -u ceb-gnrd-temp-max.service --no-pager -n 100
run busctl --system tree xyz.openbmc_project.State.FanCtrl --no-pager
for hwmon in /sys/class/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    printf '\nHWMON: %s -> %s\n' "$hwmon" "$(readlink -f "$hwmon/device")"
    for file in "$hwmon/name" "$hwmon"/fan*_input "$hwmon"/pwm* \
        "$hwmon"/temp*_label "$hwmon"/temp*_input; do
        [ -f "$file" ] || continue
        printf '%s: ' "${file##*/}"
        cat "$file" 2>&1
    done
done
section 'PSU device lifecycle'
run systemctl status ceb-gnrd-psu-detect.service --no-pager -l -n 20
run journalctl -b -u ceb-gnrd-psu-detect.service --no-pager -n 60
for address in 0058 0059 005a; do
    device=/sys/bus/i2c/devices/7-$address
    [ -d "$device" ] || continue
    run cat "$device/name"
    run readlink -f "$device/driver"
done
section 'eSPI, USB gadget and video devices'
run ls -l /sys/bus/platform/drivers/aspeed-espi-ctrl
run ls -l /sys/class/udc /dev/video0
for gadget in /sys/kernel/config/usb_gadget/*; do
    [ -d "$gadget" ] || continue
    printf '\nGADGET: %s\n' "$gadget"
    run cat "$gadget/UDC" "$gadget/idVendor" "$gadget/idProduct"
done
run journalctl -b -u xyz.openbmc_project.Chassis.Buttons.service \
    -u phosphor-button-handler.service -u phosphor-led-manager.service \
    -u obmc-ikvm.service --no-pager -n 100
section 'Kernel tail'
run dmesg | tail -n 120
