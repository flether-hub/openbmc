SUMMARY = "CEB-GNRD fan settings persistence"
DESCRIPTION = "Lets the user keep the web fan control settings across BMC reboots (and power cycles); otherwise the adaptive defaults apply after every reboot."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-fan-settings.py \
    file://ceb-gnrd-fan-settings.service \
    file://com.ctopai.CebGnrd.FanSettings.conf \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-fan-settings.service"
SYSTEMD_AUTO_ENABLE = "enable"

# python3-dbus-fast only depends on python3-core, but it imports xml.etree
# (python3-xml) and urllib (python3-netclient) at start-up.
RDEPENDS:${PN} = " \
    python3-core \
    python3-asyncio \
    python3-io \
    python3-json \
    python3-logging \
    python3-netclient \
    python3-threading \
    python3-xml \
    python3-dbus-fast \
    "

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir} ${D}${datadir}/dbus-1/system.d
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fan-settings.py ${D}${libexecdir}/ceb-gnrd-fan-settings.py
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-fan-settings.service ${D}${systemd_system_unitdir}/ceb-gnrd-fan-settings.service
    install -m 0644 ${UNPACKDIR}/com.ctopai.CebGnrd.FanSettings.conf \
        ${D}${datadir}/dbus-1/system.d/com.ctopai.CebGnrd.FanSettings.conf
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-fan-settings.py \
    ${systemd_system_unitdir}/ceb-gnrd-fan-settings.service \
    ${datadir}/dbus-1/system.d/com.ctopai.CebGnrd.FanSettings.conf \
    "