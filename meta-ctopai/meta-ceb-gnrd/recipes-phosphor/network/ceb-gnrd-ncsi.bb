SUMMARY = "Gate CEB-GNRD NC-SI on host power and BIOS POST complete"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-ncsi.service \
    file://manage-ncsi-link.sh \
"

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-ncsi.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "iproute2 systemd"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-ncsi.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-ncsi.service
    install -m 0755 ${UNPACKDIR}/manage-ncsi-link.sh \
        ${D}${libexecdir}/manage-ncsi-link.sh
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-ncsi.service ${libexecdir}/manage-ncsi-link.sh"
