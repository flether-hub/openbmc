SUMMARY = "CEB-GNRD SEL rollover"
DESCRIPTION = "Keeps the IPMI SEL in rollover mode: when it is full the oldest records are overwritten."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-sel-rollover.sh \
    file://ceb-gnrd-sel-rollover.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-sel-rollover.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "busybox"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-sel-rollover.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-sel-rollover.service
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-sel-rollover.sh \
        ${D}${libexecdir}/ceb-gnrd-sel-rollover.sh
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-sel-rollover.service ${libexecdir}/ceb-gnrd-sel-rollover.sh"
