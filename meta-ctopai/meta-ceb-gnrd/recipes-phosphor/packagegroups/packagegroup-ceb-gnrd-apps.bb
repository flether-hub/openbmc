SUMMARY = "CEB-GNRD OpenBMC virtual feature providers"
DESCRIPTION = "Provider packagegroups for the managed single-socket Xeon 6 CEB-GNRD platform."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit packagegroup

PACKAGES = " \
    ${PN}-chassis \
    ${PN}-fans \
    ${PN}-flash \
    ${PN}-system \
    "

PROVIDES += " \
    virtual/obmc-chassis-mgmt \
    virtual/obmc-fan-mgmt \
    virtual/obmc-flash-mgmt \
    virtual/obmc-system-mgmt \
    "

RPROVIDES:${PN}-chassis += "virtual-obmc-chassis-mgmt"
RPROVIDES:${PN}-fans += "virtual-obmc-fan-mgmt"
RPROVIDES:${PN}-flash += "virtual-obmc-flash-mgmt"
RPROVIDES:${PN}-system += "virtual-obmc-system-mgmt"

SUMMARY:${PN}-chassis = "CEB-GNRD chassis management"
RDEPENDS:${PN}-chassis = " \
    ${VIRTUAL-RUNTIME_obmc-chassis-state-manager} \
    obmc-phosphor-buttons-signals \
    obmc-phosphor-buttons-handler \
    ceb-gnrd-power-button-log \
    "

SUMMARY:${PN}-fans = "CEB-GNRD fan management"
RDEPENDS:${PN}-fans = " \
    ${VIRTUAL-RUNTIME_obmc-fan-control} \
    ceb-gnrd-fan-services \
    ceb-gnrd-fan-settings \
    ceb-gnrd-temp-max \
    "

SUMMARY:${PN}-flash = "CEB-GNRD firmware management"
RDEPENDS:${PN}-flash = " \
    phosphor-software-manager \
    phosphor-software-manager-download-mgr \
    phosphor-software-manager-updater \
    phosphor-ipmi-flash \
    "

SUMMARY:${PN}-system = "CEB-GNRD system management"
RDEPENDS:${PN}-system = " \
    phosphor-dbus-monitor \
    ceb-gnrd-psu-detect \
    ceb-gnrd-rtc-sync \
    ceb-gnrd-boot-progress \
    ceb-gnrd-sel-logrotate \
    "
