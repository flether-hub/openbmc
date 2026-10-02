FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 'ipmitool fru gen [file]': interactive generator for a FRU image with chassis,
# board and product info areas (placeholder defaults, format hints per field).
# The product name shown by "mc info" comes from a built-in table: add CEB-GNR-D.
SRC_URI:append = " \
    file://0001-ipmitool-fru-add-gen-command.patch \
    file://0002-ipmitool-add-ceb-gnrd-product-name.patch \
    "

# ipmitool shows the Manufacturer Name of "mc info" by looking the ID up in the
# IANA enterprise number file under ${datadir}/misc, which is a data file of the
# recipe, not part of the ipmitool source, so it cannot be patched.  Add the
# CTOPAI entry (6659 = 0x1A03) to it, or create the file when the distro does not
# ship it.
do_install:append() {
    f=${D}${datadir}/misc/enterprise-numbers
    install -d ${D}${datadir}/misc
    if ! grep -q '^6659$' $f 2>/dev/null; then
        printf '6659\n  CTOPAI\n    -\n      -\n' >> $f
    fi
}

FILES:${PN}:append = " ${datadir}/misc"