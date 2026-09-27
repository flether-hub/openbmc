#!/bin/bash
#
# ceb-gnrd BIOS update script.
# Adapted from meta-ibm/meta-sbp1 for the Intel Xeon 6 (Granite Rapids) platform.
#
# TODO: Verify and adjust the following hardware-specific values:
#   - IPMB_BUS: IPMB channel number for ME/SPS communication
#   - MTD_DEV: MTD device number for the host BIOS SPI region
#   - FLASH_OVERRIDE_GPIO: GPIO name that enables flash security override
#   - ME_IPMI_ADDR: IPMI slave address of the Management Engine
#
set -e

IMAGE_FILE=$(find "$1" -name "*.FD" -o -name "*.fd" -o -name "*.bin" | head -n 1)

IPMB_OBJ="xyz.openbmc_project.Ipmi.Channel.Ipmb"
IPMB_PATH="/xyz/openbmc_project/Ipmi/Channel/Ipmb"
IPMB_INTF="org.openbmc.Ipmb"

# TODO: Adjust IPMB bus/channel for your platform
IPMB_BUS=1

# TODO: Adjust MTD device number for the host BIOS SPI region
MTD_DEV=12

# TODO: Adjust GPIO name for flash security override
FLASH_OVERRIDE_GPIO="FM_FLASH_SEC_OVRD"

# TODO: Adjust ME IPMI slave address (0x2e is typical for Intel SPS/ME)
ME_IPMI_ADDR=0x2e

# ME IPMI commands
# Force recovery mode: NetFn=0x2e, Cmd=0xdf, data=0x57 0x01 0x00 0x01
ME_CMD_RECOVER="${IPMB_BUS} ${ME_IPMI_ADDR} 0 0xdf 4 0x57 0x01 0x00 0x01"
# Cold reset: NetFn=0x06, Cmd=0x02
ME_CMD_RESET="${IPMB_BUS} 0x06 0 0x2 0"
# Get Device ID: NetFn=0x06, Cmd=0x01
ME_GET_DEVICE_ID="${IPMB_BUS} 0x06 0 0x1 0"

echo "BIOS upgrade started at $(date)"

power_status() {
    st=$(busctl get-property xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis CurrentPowerState 2>/dev/null \
        | cut -d"." -f6)
    if [ "$st" == "On\"" ]; then
        echo "on"
    else
        echo "off"
    fi
}

power_off() {
    echo "Shutting down host"
    busctl set-property xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis RequestedPowerTransition \
        s xyz.openbmc_project.State.Chassis.Transition.Off
    for i in $(seq 1 30); do
        if [ "$(power_status)" == "off" ]; then
            break
        fi
        sleep 1
    done
    if [ "$(power_status)" != "off" ]; then
        echo "Failed to power off host"
        exit 1
    fi
}

power_on() {
    echo "Powering on host"
    busctl set-property xyz.openbmc_project.State.Chassis \
        /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis RequestedPowerTransition \
        s xyz.openbmc_project.State.Chassis.Transition.On
    for i in $(seq 1 30); do
        if [ "$(power_status)" == "on" ]; then
            break
        fi
        sleep 1
    done
    if [ "$(power_status)" != "on" ]; then
        echo "Failed to power on host"
        exit 1
    fi
}

me_wait_poweron() {
    echo "Waiting for ME/SPS firmware to start..."
    for i in $(seq 1 30); do
        # shellcheck disable=SC2086
        if busctl call --timeout=1 "$IPMB_OBJ" "$IPMB_PATH" "$IPMB_INTF" \
            sendRequest yyyyay $ME_GET_DEVICE_ID 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "Failed to communicate with ME/SPS firmware"
    exit 1
}

me_force_recovery_mode() {
    echo "Setting ME to recovery mode"
    # shellcheck disable=SC2086
    busctl call "$IPMB_OBJ" "$IPMB_PATH" "$IPMB_INTF" \
        sendRequest yyyyay $ME_CMD_RECOVER
}

me_reset() {
    echo "Resetting ME to boot from new firmware"
    # shellcheck disable=SC2086
    busctl call "$IPMB_OBJ" "$IPMB_PATH" "$IPMB_INTF" \
        sendRequest yyyyay $ME_CMD_RESET
}

# Step 1: Power off the host
power_off

# Step 2: Enable flash security override GPIO
echo "Enabling flash security override (${FLASH_OVERRIDE_GPIO})"
gpioset "$(gpiofind "${FLASH_OVERRIDE_GPIO}")"=1

# Step 3: Power on the host (ME boots but host stays in recovery)
power_on

# Step 4: Wait for ME/SPS to be ready
me_wait_poweron

# Step 5: Force ME into recovery mode
me_force_recovery_mode

# Step 6: Flash the BIOS image
if [ -n "${IMAGE_FILE}" ] && [ -e "${IMAGE_FILE}" ]; then
    echo "Flashing BIOS image: ${IMAGE_FILE}"
    flashrom -p "linux_mtd:dev=${MTD_DEV}" -w "${IMAGE_FILE}"
else
    echo "ERROR: BIOS image not found in $1"
    exit 1
fi

# Step 7: Reset ME to boot from new firmware
me_reset

sleep 5

# Step 8: Power off the host
power_off

# Step 9: Disable flash security override GPIO
echo "Disabling flash security override (${FLASH_OVERRIDE_GPIO})"
gpioset "$(gpiofind "${FLASH_OVERRIDE_GPIO}")"=0

# Clean up cached BIOS version
rm -f /var/cache/bios_version

echo "BIOS upgrade completed at $(date)"
