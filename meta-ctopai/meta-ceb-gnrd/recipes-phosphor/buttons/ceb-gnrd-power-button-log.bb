SUMMARY = "CEB-GNRD power button press logging"
DESCRIPTION = "Records presses of the chassis power button (BMC_POWER_BUTTON_INPUT) in the IPMI SEL and the journal.  Detection only: it never changes the host power state or drives the CPU power button output."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-power-button-log.service \
    file://ceb-gnrd-power-button-log.sh \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-power-button-log.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "libgpiod-tools util-linux systemd"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-power-button-log.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-power-button-log.service
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-power-button-log.sh \
        ${D}${libexecdir}/ceb-gnrd-power-button-log.sh
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/ceb-gnrd-power-button-log.service \
    ${libexecdir}/ceb-gnrd-power-button-log.sh \
    "