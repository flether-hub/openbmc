SUMMARY = "CEB-GNRD fan ownership and fault logging"
DESCRIPTION = "Selects BMC fan ownership when the configured fan-control service is ready."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://ceb-gnrd-fan-owner.service \
    file://ceb-gnrd-fan-owner.sh \
    file://ceb-gnrd-fan-release.sh \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-fan-owner.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "libgpiod-tools util-linux"

do_install() {
    install -d ${D}${sbindir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fan-owner.sh \
        ${D}${sbindir}/ceb-gnrd-fan-owner
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fan-release.sh \
        ${D}${sbindir}/ceb-gnrd-fan-release
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-fan-owner.service \
        ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${sbindir}/ceb-gnrd-fan-owner \
    ${sbindir}/ceb-gnrd-fan-release \
    ${systemd_system_unitdir}/ceb-gnrd-fan-owner.service \
    "
