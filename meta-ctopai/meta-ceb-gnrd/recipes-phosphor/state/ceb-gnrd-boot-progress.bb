SUMMARY = "CEB-GNRD host boot progress from BIOS POST codes"
DESCRIPTION = "Publishes xyz.openbmc_project.State.Boot.Progress on /xyz/openbmc_project/state/host0 from the port 80 POST codes (phosphor-host-postd), for the IPMI Boot_Progress sensor and the web discrete sensor table."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-boot-progress.py \
    file://ceb-gnrd-boot-progress.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-boot-progress.service"
SYSTEMD_AUTO_ENABLE = "enable"

# python3-dbus-fast only depends on python3-core, but it imports xml.etree
# (python3-xml) and urllib (python3-netclient) at start-up.
RDEPENDS:${PN} = " \
    python3-core \
    python3-asyncio \
    python3-logging \
    python3-netclient \
    python3-xml \
    python3-dbus-fast \
    "

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-boot-progress.py ${D}${libexecdir}/ceb-gnrd-boot-progress.py
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-boot-progress.service ${D}${systemd_system_unitdir}/ceb-gnrd-boot-progress.service
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-boot-progress.py \
    ${systemd_system_unitdir}/ceb-gnrd-boot-progress.service \
    "
