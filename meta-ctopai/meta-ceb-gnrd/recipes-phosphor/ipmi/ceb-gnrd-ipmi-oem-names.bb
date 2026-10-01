SUMMARY = "CEB-GNRD IANA enterprise name for ipmitool"
DESCRIPTION = "ipmitool looks the Manufacturer ID up in /usr/share/misc/enterprise-numbers; ship one entry so mc info shows CTOPAI."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch

FILESEXTRAPATHS:prepend := "${THISDIR}/ceb-gnrd-ipmi-oem-names:"
SRC_URI = "file://enterprise-numbers"
S = "${UNPACKDIR}"

do_install() {
    install -D -m 0644 ${UNPACKDIR}/enterprise-numbers ${D}${datadir}/misc/enterprise-numbers
}

FILES:${PN} += "${datadir}/misc/enterprise-numbers"