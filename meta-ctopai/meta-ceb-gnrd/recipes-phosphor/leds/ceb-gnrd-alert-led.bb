SUMMARY = "CEB-GNRD system alert LED policy"
DESCRIPTION = "Drives the system alert LED from voltage alarms and host boot/watchdog failures."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-alert-led.service \
    file://ceb-gnrd-alert-led.py \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-alert-led.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "python3-core python3-json python3-logging python3-threading systemd phosphor-watchdog"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-alert-led.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-alert-led.service
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-alert-led.py \
        ${D}${libexecdir}/ceb-gnrd-alert-led.py
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-alert-led.service ${libexecdir}/ceb-gnrd-alert-led.py"
