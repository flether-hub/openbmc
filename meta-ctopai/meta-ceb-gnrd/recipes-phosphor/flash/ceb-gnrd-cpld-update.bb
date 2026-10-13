SUMMARY = "CEB-GNRD EF3L90 background JTAG programming with manual AC activation"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

# Local sources are kept below the recipe-specific files directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}/files:"

SRC_URI = "file://ceb-gnrd-cpld-update.py file://cpld_jtag.py file://cpld-update.json file://ceb-gnrd-cpld-update.service file://com.ctopai.CebGnrd.CpldUpdate.conf"
S = "${UNPACKDIR}"
SYSTEMD_SERVICE:${PN} = "ceb-gnrd-cpld-update.service"
SYSTEMD_AUTO_ENABLE = "enable"
RDEPENDS:${PN} = "python3-core python3-asyncio python3-dbus-fast python3-xml python3-logging python3-threading python3-ctypes python3-fcntl python3-json python3-crypt python3-math systemd phosphor-software-manager-updater"

do_install() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-cpld-update.py ${D}${libexecdir}/ceb-gnrd-cpld-update.py
    install -Dm0755 ${UNPACKDIR}/cpld_jtag.py ${D}${libexecdir}/cpld_jtag.py
    install -Dm0644 ${UNPACKDIR}/cpld-update.json ${D}${sysconfdir}/ceb-gnrd/cpld-update.json
    install -Dm0644 ${UNPACKDIR}/ceb-gnrd-cpld-update.service ${D}${systemd_system_unitdir}/ceb-gnrd-cpld-update.service
    install -Dm0644 ${UNPACKDIR}/com.ctopai.CebGnrd.CpldUpdate.conf ${D}${datadir}/dbus-1/system.d/com.ctopai.CebGnrd.CpldUpdate.conf
}
FILES:${PN} += "${libexecdir} ${systemd_system_unitdir} ${datadir}/dbus-1/system.d"
CONFFILES:${PN} += "${sysconfdir}/ceb-gnrd/cpld-update.json"
