SUMMARY = "CEB-GNRD CPU and DIMM maximum temperature sensors"
DESCRIPTION = "Publishes CPU_MAX_TEMP and DIMM_MAX_TEMP D-Bus sensors (the hottest PECI CPU core and DIMM temperature) used as the only inputs of the automatic fan control."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-temp-max.py \
    file://ceb-gnrd-temp-max.service \
    file://10-ceb-gnrd-temp-max.conf \
    file://xyz.openbmc_project.CebGnrd.TempMax.conf \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-temp-max.service"
SYSTEMD_AUTO_ENABLE = "enable"

# python3-dbus-fast only depends on python3-core, but it imports xml.etree
# (python3-xml) and urllib (python3-netclient) at start-up.
RDEPENDS:${PN} = " \
    python3-core \
    python3-asyncio \
    python3-io \
    python3-logging \
    python3-math \
    python3-netclient \
    python3-threading \
    python3-xml \
    python3-dbus-fast \
    "

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir} \
        ${D}${systemd_system_unitdir}/phosphor-pid-control.service.d \
        ${D}${datadir}/dbus-1/system.d
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-temp-max.py ${D}${libexecdir}/ceb-gnrd-temp-max.py
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-temp-max.service ${D}${systemd_system_unitdir}/ceb-gnrd-temp-max.service
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-temp-max.conf \
        ${D}${systemd_system_unitdir}/phosphor-pid-control.service.d/10-ceb-gnrd-temp-max.conf
    install -m 0644 ${UNPACKDIR}/xyz.openbmc_project.CebGnrd.TempMax.conf \
        ${D}${datadir}/dbus-1/system.d/xyz.openbmc_project.CebGnrd.TempMax.conf
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-temp-max.py \
    ${systemd_system_unitdir}/ceb-gnrd-temp-max.service \
    ${systemd_system_unitdir}/phosphor-pid-control.service.d \
    ${datadir}/dbus-1/system.d/xyz.openbmc_project.CebGnrd.TempMax.conf \
    "