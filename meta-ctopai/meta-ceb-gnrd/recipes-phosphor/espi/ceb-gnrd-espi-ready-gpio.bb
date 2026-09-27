SUMMARY = "CEB-GNRD eSPI-ready GPIO helper"
DESCRIPTION = "Raises a configurable GPIO after the AST eSPI platform device is ready."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://ceb-gnrd-espi-ready-gpio.sh \
    file://ceb-gnrd-espi-ready-gpio.service \
    file://ceb-gnrd-espi-ready-gpio.default \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-espi-ready-gpio.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "libgpiod-tools"

do_install() {
    install -d ${D}${sbindir} ${D}${sysconfdir}/default
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-espi-ready-gpio.sh \
        ${D}${sbindir}/ceb-gnrd-espi-ready-gpio
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-espi-ready-gpio.default \
        ${D}${sysconfdir}/default/ceb-gnrd-espi-ready-gpio

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-espi-ready-gpio.service \
        ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${sysconfdir}/default/ceb-gnrd-espi-ready-gpio \
    ${sbindir}/ceb-gnrd-espi-ready-gpio \
    ${systemd_system_unitdir}/ceb-gnrd-espi-ready-gpio.service \
    "
