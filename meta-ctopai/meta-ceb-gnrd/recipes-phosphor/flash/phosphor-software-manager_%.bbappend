FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-bmc-update-partition-selection.patch \
    file://bios-update.sh \
    file://bios-layout.txt \
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
    # default BIOS flash layout (regions) used by bios-update.sh
    install -D -m 0644 ${UNPACKDIR}/bios-layout.txt ${D}${datadir}/ceb-gnrd/bios-layout.txt
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/obmc-flash-host-bios@.service \
        ${D}${systemd_system_unitdir}/

    # AUTO_ENABLE above is disabled for the whole updater package, which includes
    # the BMC image updater daemon.  That daemon provides the BMC version object
    # (mc info firmware revision, web "running image") and handles firmware
    # uploads, so it must start at boot: enable just that unit with a static
    # symlink.
    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../xyz.openbmc_project.Software.BMC.Updater.service \
        ${D}${systemd_system_unitdir}/multi-user.target.wants/xyz.openbmc_project.Software.BMC.Updater.service
}

FILES:${PN}-updater:append:ceb-gnrd = " \
    ${datadir}/ceb-gnrd/bios-layout.txt \
    ${systemd_system_unitdir}/multi-user.target.wants/xyz.openbmc_project.Software.BMC.Updater.service \
    "
