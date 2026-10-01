SUMMARY = "CEB-GNRD IPMI I2C Master Write-Read allowlist"
DESCRIPTION = "Restrict IPMI raw I2C access to the six CEB-GNRD PCIe slot buses."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch python3native

# Runtime provider named in VIRTUAL-RUNTIME_phosphor-ipmi-providers.
RPROVIDES:${PN} += "ceb-gnrd-ipmi"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://generate_i2c_allowlist.py"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${datadir}/ipmi-providers
    ${PYTHON} ${UNPACKDIR}/generate_i2c_allowlist.py \
        ${D}${datadir}/ipmi-providers/master_write_read_white_list.json
}

FILES:${PN} += "${datadir}/ipmi-providers/master_write_read_white_list.json"
