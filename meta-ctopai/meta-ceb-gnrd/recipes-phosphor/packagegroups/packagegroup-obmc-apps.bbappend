# ceb-gnrd (Intel Xeon 6 platform) applications.
# Reference: meta-ibm/meta-sbp1 (Intel server board).
#
#  - entity-manager + fru-device: probe the board FRU EEPROMs over I2C and
#    publish the FRU contents on D-Bus (xyz.openbmc_project.FruDevice)
#  - dbus-sensors: PECI-based CPU/DIMM temperature sensors for the Intel
#    host (IntelCPUSensor) plus the generic sensor set
#  - phosphor-host-postd: snoops BIOS POST codes (I/O port 0x80) via
#    LPC/eSPI and publishes them on D-Bus
#  - phosphor-post-code-manager: records BIOS POST code history
#  - biosconfig-manager: remote BIOS setup (menu) configuration via BMC
#    (Redfish/PLDM BIOS attribute sync)
#  - phosphor-software-manager: host BIOS update via flashrom over MTD
#  - phosphor-ipmi-flash: IPMI in-band firmware update (BLOB protocol)
#  - phosphor-state-manager-chassis: chassis power state management
#  - ipmitool: on-BMC IPMI client for FRU/sensor debugging
#  - ceb-gnrd-check: board functional check and log collection (/usr/bin/ceb-gnrd-check)
RDEPENDS:${PN}-extras:append:ceb-gnrd = " \
        entity-manager \
        fru-device \
        dbus-sensors \
        phosphor-host-postd \
        phosphor-post-code-manager \
        biosconfig-manager \
        phosphor-software-manager \
        phosphor-ipmi-flash \
        phosphor-state-manager-chassis \
        ceb-gnrd-ncsi \
        obmc-phosphor-buttons-signals \
        obmc-phosphor-buttons-handler \
        phosphor-ipmi-host \
        phosphor-sel-logger \
        phosphor-time-manager \
        phosphor-watchdog \
        ceb-gnrd-espi-heartbeat \
        ceb-gnrd-alert-led \
        phosphor-u-boot-mgr \
        u-boot-fw-utils \
        ipmitool \
        curl \
        openssh-scp \
        ceb-gnrd-check \
        ceb-gnrd-health \
        "

RDEPENDS:${PN}-extras:remove:ceb-gnrd = "phosphor-state-manager-chassis"
RDEPENDS:${PN}-chassis-state-mgmt:remove:ceb-gnrd = "obmc-phosphor-power"

# The BMC must never shut the system down because of a sensor threshold.
# phosphor-fan-monitor pulls in phosphor-fan's sensor-monitor ("Sensor Monitor"),
# which powers the system off on HardShutdown / SoftShutdown threshold alarms.
# Fans are controlled by phosphor-pid-control here, so neither is needed.
RDEPENDS:${PN}-fan-control:remove:ceb-gnrd = "phosphor-fan-monitor"
