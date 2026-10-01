SUMMARY = "CEB-GNRD chassis power button forwarding"
DESCRIPTION = "Forwards the chassis button pulse to the CPU and records an IPMI SEL event."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-power-button.service \
    file://ceb-gnrd-power-button.sh \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-power-button.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "libgpiod-tools systemd"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-power-button.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-power-button.service
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-power-button.sh \
        ${D}${libexecdir}/ceb-gnrd-power-button.sh
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-power-button.service ${libexecdir}/ceb-gnrd-power-button.sh"
