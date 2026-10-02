SUMMARY = "CEB-GNRD BMC health: service hang monitor and watchdog reset logging"
DESCRIPTION = "ceb-gnrd-health-monitor probes the important BMC services and restarts (or reboots the BMC for) a hung one; ceb-gnrd-wdt-reset-log writes a SEL record when the BMC was restarted by the hardware watchdog without a clean shutdown."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-health-monitor.sh \
    file://ceb-gnrd-health-monitor.service \
    file://ceb-gnrd-wdt-reset-log.sh \
    file://ceb-gnrd-wdt-reset-log.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-health-monitor.service ceb-gnrd-wdt-reset-log.service"
SYSTEMD_AUTO_ENABLE = "enable"

# busctl comes with systemd; the HTTP probe uses curl.
RDEPENDS:${PN} = "curl"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-health-monitor.sh ${D}${libexecdir}/ceb-gnrd-health-monitor.sh
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-wdt-reset-log.sh ${D}${libexecdir}/ceb-gnrd-wdt-reset-log.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-health-monitor.service ${D}${systemd_system_unitdir}/ceb-gnrd-health-monitor.service
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-wdt-reset-log.service ${D}${systemd_system_unitdir}/ceb-gnrd-wdt-reset-log.service
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-health-monitor.sh \
    ${libexecdir}/ceb-gnrd-wdt-reset-log.sh \
    ${systemd_system_unitdir}/ceb-gnrd-health-monitor.service \
    ${systemd_system_unitdir}/ceb-gnrd-wdt-reset-log.service \
    "
