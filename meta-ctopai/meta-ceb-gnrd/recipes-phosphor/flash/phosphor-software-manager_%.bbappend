FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

SRC_URI:append:ceb-gnrd = " \
    file://bios-update.sh \
    file://obmc-flash-host-bios@.service \
    "

# Use the updater daemon compatible with the board BIOS update flow.
PACKAGECONFIG:remove:ceb-gnrd = "software-update-dbus-interface"
PACKAGECONFIG:append:ceb-gnrd = " flash_bios"

# The updater units are triggered by D-Bus and OpenBMC targets.  Do not let
# the generated systemd postinst call `systemctl enable` for these units in
# the rootfs fakeroot environment; some are static/triggered units and return
# failure there.  The unit files and explicit OpenBMC links are still shipped.
SYSTEMD_AUTO_ENABLE:${PN}-updater:ceb-gnrd = "disable"

# The host BIOS service belongs to the updater subpackage, so its runtime
# tools must be attached there rather than only to the empty main package.
RDEPENDS:${PN}-updater:append:ceb-gnrd = " \
    bash \
    flashrom \
    libgpiod-tools \
    "

# Keep U-Boot environment variables, including board MAC addresses, managed
# through the persistent u-boot-env partition during BMC update workflows.
RDEPENDS:${PN}:append:ceb-gnrd = " phosphor-u-boot-mgr "

do_install:append:ceb-gnrd() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/bios-update.sh ${D}${sbindir}/
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/obmc-flash-host-bios@.service \
        ${D}${systemd_system_unitdir}/
}
