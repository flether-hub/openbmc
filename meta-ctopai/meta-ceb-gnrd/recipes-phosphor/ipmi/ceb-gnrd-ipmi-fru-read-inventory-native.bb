SUMMARY = "CEB-GNRD FRU read map for phosphor-ipmi-host"
DESCRIPTION = "Maps the board's inventory properties back to IPMI FRU fields for Read FRU Data (ipmitool fru print).  Same mapping as the one phosphor-ipmi-fru uses to fill the inventory, so a FRU that was read from the EEPROM or written with ipmitool reads back.  Replaces the example map of meta-phosphor."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"
PROVIDES += "virtual/phosphor-ipmi-fru-read-inventory"

inherit phosphor-ipmi-host
inherit native

FILESEXTRAPATHS:prepend := "${THISDIR}/../configuration/ceb-gnrd-yaml-config:"
SRC_URI = "file://ceb-gnrd-ipmi-fru.yaml"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${config_datadir}
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-ipmi-fru.yaml ${D}${config_datadir}/config.yaml
}
