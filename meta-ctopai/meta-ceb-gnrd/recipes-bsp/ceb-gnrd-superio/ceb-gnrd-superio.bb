SUMMARY = "Disable the AST2600 built-in SuperIO"
DESCRIPTION = "Sets SCU510[3] so the host BIOS does not detect a BMC SuperIO at 0x2E/0x2F and does not route COM1 to the BMC, which would hang the BIOS on the unanswered line status register."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-disable-superio.sh \
    file://ceb-gnrd-disable-superio.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-disable-superio.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "busybox"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-disable-superio.sh ${D}${libexecdir}/ceb-gnrd-disable-superio.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-disable-superio.service ${D}${systemd_system_unitdir}/ceb-gnrd-disable-superio.service
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-disable-superio.sh \
    ${systemd_system_unitdir}/ceb-gnrd-disable-superio.service \
    "