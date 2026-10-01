SUMMARY = "CEB-GNRD phosphor LED group configuration"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit native

PROVIDES += "virtual/phosphor-led-manager-config-native"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://led.json"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${datadir}/phosphor-led-manager
    install -m 0644 ${UNPACKDIR}/led.json \
        ${D}${datadir}/phosphor-led-manager/led.json
}
