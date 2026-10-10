SUMMARY = "CEB-GNRD persistent diagnostic storage budget"
DESCRIPTION = "Migrate legacy diagnostic archives and monitor rwfs headroom. Rsyslog rotates text logs synchronously in its writer."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-storage-budget.py \
    file://ceb-gnrd-sel-logrotate.service \
    file://ceb-gnrd-sel-logrotate.timer \
    file://ceb-gnrd-log-storage-cleanup.sh \
    file://ceb-gnrd-log-storage-cleanup.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-sel-logrotate.timer ceb-gnrd-log-storage-cleanup.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "python3-core rsyslog"

do_install() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-storage-budget.py ${D}${libexecdir}/ceb-gnrd-storage-budget
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-log-storage-cleanup.sh ${D}${libexecdir}/ceb-gnrd-log-storage-cleanup
    install -Dm0644 ${UNPACKDIR}/ceb-gnrd-log-storage-cleanup.service ${D}${systemd_system_unitdir}/ceb-gnrd-log-storage-cleanup.service
    install -d ${D}${sysconfdir}/ceb-gnrd ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-sel-logrotate.service ${D}${systemd_system_unitdir}/ceb-gnrd-sel-logrotate.service
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-sel-logrotate.timer ${D}${systemd_system_unitdir}/ceb-gnrd-sel-logrotate.timer
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-log-storage-cleanup \
    ${systemd_system_unitdir}/ceb-gnrd-log-storage-cleanup.service \
    ${libexecdir}/ceb-gnrd-storage-budget \
    ${systemd_system_unitdir}/ceb-gnrd-sel-logrotate.service \
    ${systemd_system_unitdir}/ceb-gnrd-sel-logrotate.timer \
    "
