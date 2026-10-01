SUMMARY = "CEB-GNRD PSU presence monitor"
DESCRIPTION = "Creates the CRPS PMBus devices only for the installed PSU modules (0, 1 or 2 of 0x58/0x59/0x5a) so empty slots do not log probe errors."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-psu-detect.sh \
    file://ceb-gnrd-psu-detect.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-psu-detect.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "i2c-tools"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-psu-detect.sh ${D}${libexecdir}/ceb-gnrd-psu-detect.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-psu-detect.service ${D}${systemd_system_unitdir}/ceb-gnrd-psu-detect.service
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-psu-detect.sh \
    ${systemd_system_unitdir}/ceb-gnrd-psu-detect.service \
    "