SUMMARY = "CEB-GNRD PSU startup detection"
DESCRIPTION = "Detects installed CRPS PSU modules at BMC startup and selects megcrps800 for MEG-CRPS800AOP or generic pmbus for other models before starting PSU sensors."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-psu-detect.sh \
    file://ceb-gnrd-psu-detect.service \
    file://psusensor-psu-detect.conf \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-psu-detect.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "i2c-tools"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-psu-detect.sh ${D}${libexecdir}/ceb-gnrd-psu-detect.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-psu-detect.service ${D}${systemd_system_unitdir}/ceb-gnrd-psu-detect.service
    install -D -m 0644 ${UNPACKDIR}/psusensor-psu-detect.conf \
        ${D}${systemd_system_unitdir}/xyz.openbmc_project.psusensor.service.d/psu-detect.conf
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-psu-detect.sh \
    ${systemd_system_unitdir}/ceb-gnrd-psu-detect.service \
    ${systemd_system_unitdir}/xyz.openbmc_project.psusensor.service.d/psu-detect.conf \
    "
