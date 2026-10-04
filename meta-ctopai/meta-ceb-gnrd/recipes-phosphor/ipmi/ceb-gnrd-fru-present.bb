SUMMARY = "CEB-GNRD: mark the board FRU present in the inventory"
DESCRIPTION = "ipmid reports a FRU as not present (and ipmitool fru print/write fail) until its inventory object has Item.Present = true, which ipmi-fru-parser only sets after parsing FRU data.  This oneshot sets it at every boot so a blank FRU EEPROM can be written through IPMI."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files/ceb-gnrd-fru-present:"
SRC_URI = " \
    file://ceb-gnrd-fru-present.sh \
    file://ceb-gnrd-fru-present.service \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-fru-present.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "systemd phosphor-inventory-manager"

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-fru-present.sh ${D}${libexecdir}/ceb-gnrd-fru-present.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-fru-present.service ${D}${systemd_system_unitdir}/ceb-gnrd-fru-present.service
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-fru-present.sh \
    ${systemd_system_unitdir}/ceb-gnrd-fru-present.service \
    "
