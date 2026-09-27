SUMMARY = "CEB-GNRD hardware integration contract"
DESCRIPTION = "Board-specific sensor, event, control and management contract for CEB-GNRD."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://ceb-gnrd-hardware-contract.yaml"
S = "${UNPACKDIR}"

do_install() {
    install -m 0644 -D ${UNPACKDIR}/ceb-gnrd-hardware-contract.yaml \
        ${D}${datadir}/ceb-gnrd/ceb-gnrd-hardware-contract.yaml
}

FILES:${PN} += "${datadir}/ceb-gnrd"
