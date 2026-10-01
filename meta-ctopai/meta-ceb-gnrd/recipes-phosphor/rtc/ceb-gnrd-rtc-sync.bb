SUMMARY = "CEB-GNRD: set the system clock from the RTC at boot"
DESCRIPTION = "The BMC system time (and therefore SEL timestamps) comes from the battery-backed NCT3015Y RTC by default."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://ceb-gnrd-rtc-sync.service"

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-rtc-sync.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "util-linux-hwclock"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-rtc-sync.service \
        ${D}${systemd_system_unitdir}/ceb-gnrd-rtc-sync.service
}

FILES:${PN} += "${systemd_system_unitdir}/ceb-gnrd-rtc-sync.service"
