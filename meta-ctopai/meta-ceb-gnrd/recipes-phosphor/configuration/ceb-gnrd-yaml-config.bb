SUMMARY = "FRU YAML configuration for ceb-gnrd"
DESCRIPTION = "Provides IPMI FRU read mapping and extra properties \
for the ceb-gnrd (Intel Xeon 6) platform."
PR = "r1"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch

SRC_URI:ceb-gnrd = " \
    file://ceb-gnrd-ipmi-fru.yaml \
    file://ceb-gnrd-ipmi-fru-properties.yaml \
    "

S = "${UNPACKDIR}"

do_install:ceb-gnrd() {
    install -m 0644 -D ceb-gnrd-ipmi-fru.yaml \
        ${D}${datadir}/${BPN}/ipmi-fru-read.yaml
    install -m 0644 -D ceb-gnrd-ipmi-fru-properties.yaml \
        ${D}${datadir}/${BPN}/ipmi-extra-properties.yaml
}

FILES:${PN}-dev = " \
    ${datadir}/${BPN}/ipmi-fru-read.yaml \
    ${datadir}/${BPN}/ipmi-extra-properties.yaml \
    "

ALLOW_EMPTY:${PN} = "1"
