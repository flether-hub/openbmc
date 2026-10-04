SUMMARY = "CEB-GNRD board FRU: default image for a blank EEPROM, rescan after a write"
DESCRIPTION = "ipmitool fru print/write go through fru-device, which only knows EEPROMs holding a valid FRU.  ceb-gnrd-fru-init writes a default placeholder FRU into a blank board FRU EEPROM at boot so the FRU exists as FRU 0 and can be written with ipmitool; ceb-gnrd-fru-rescan asks fru-device for a rescan after every FRU write so the new data is visible at once."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-fru-init.sh \
    file://ceb-gnrd-fru-init.service \
    file://ceb-gnrd-fru-rescan.sh \
    file://ceb-gnrd-fru-rescan.service \
    file://default-fru.bin \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-fru-init.service ceb-gnrd-fru-rescan.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "systemd"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir} ${D}${datadir}/ceb-gnrd
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fru-init.sh ${D}${libexecdir}/ceb-gnrd-fru-init.sh
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fru-rescan.sh ${D}${libexecdir}/ceb-gnrd-fru-rescan.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-fru-init.service ${D}${systemd_system_unitdir}/ceb-gnrd-fru-init.service
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-fru-rescan.service ${D}${systemd_system_unitdir}/ceb-gnrd-fru-rescan.service
    install -m 0644 ${UNPACKDIR}/default-fru.bin ${D}${datadir}/ceb-gnrd/default-fru.bin
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-fru-init.sh \
    ${libexecdir}/ceb-gnrd-fru-rescan.sh \
    ${systemd_system_unitdir}/ceb-gnrd-fru-init.service \
    ${systemd_system_unitdir}/ceb-gnrd-fru-rescan.service \
    ${datadir}/ceb-gnrd/default-fru.bin \
    "
