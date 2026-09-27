FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

SRC_URI:append:ceb-gnrd = " \
    file://bios-update.sh \
    file://obmc-flash-host-bios@.service \
    "

# Use the updater daemon compatible with the board BIOS update flow.
PACKAGECONFIG:remove:ceb-gnrd = "software-update-dbus-interface"
PACKAGECONFIG:append:ceb-gnrd = " flash_bios"

# The host BIOS service belongs to the updater subpackage, so its runtime
# tools must be attached there rather than only to the empty main package.
RDEPENDS:${PN}-updater:append:ceb-gnrd = " \
    bash \
    flashrom \
    libgpiod-tools \
    phosphor-ipmi-ipmb \
    "

do_install:append:ceb-gnrd() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/bios-update.sh ${D}${sbindir}/
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/obmc-flash-host-bios@.service \
        ${D}${systemd_system_unitdir}/
}
