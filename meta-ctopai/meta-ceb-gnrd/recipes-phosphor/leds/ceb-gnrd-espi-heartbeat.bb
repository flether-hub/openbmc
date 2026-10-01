SUMMARY = "Enable the CEB-GNRD BMC heartbeat after eSPI Peripheral is ready"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-espi-heartbeat.service \
    file://wait-for-espi-driver.sh \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-espi-heartbeat.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "systemd"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -d ${D}${libexecdir}
    install -m 0644 ${WORKDIR}/ceb-gnrd-espi-heartbeat.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-espi-heartbeat.service
    install -m 0755 ${WORKDIR}/wait-for-espi-driver.sh \
        ${D}${libexecdir}/wait-for-espi-driver.sh
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-espi-heartbeat.service ${libexecdir}/wait-for-espi-driver.sh"
