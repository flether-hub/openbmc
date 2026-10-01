# ipmitool shows the Manufacturer Name of "mc info" by looking the ID up in the
# IANA enterprise number file under ${datadir}/misc.  Add the CEB-GNR-D entry to
# that file (the full IANA list when the distro ships it, otherwise a new
# file).  It runs as a post function so it also works when another layer
# installs the file from its own do_install:append.
ceb_gnrd_enterprise_name() {
    f=${D}${datadir}/misc/enterprise-numbers
    install -d ${D}${datadir}/misc
    if ! grep -q '^16776960$' $f 2>/dev/null; then
        printf '16776960\n  CTOPAI\n    -\n      -\n' >> $f
    fi
}
do_install[postfuncs] += "ceb_gnrd_enterprise_name"

FILES:${PN}:append = " ${datadir}/misc"

# "mc info" prints the Product Name from a built-in table; add the CEB-GNR-D
# entry (manufacturer 16776960, product 3346 = 0x0d12) as the first row.
do_ceb_gnrd_product_name() {
    f=${S}/lib/ipmi_strings.c
    grep -q 'ipmi_oem_product_info\[\]' $f || bbfatal "ipmi_oem_product_info table not found in $f"
    if ! grep -q 'CEB-GNR-D' $f; then
        sed -i '/ipmi_oem_product_info\[\][[:space:]]*=[[:space:]]*{/a\    { 16776960, 3346, "CEB-GNR-D" },' $f
    fi
    grep -q 'CEB-GNR-D' $f || bbfatal "could not add the CEB-GNR-D product name to $f"
}
addtask ceb_gnrd_product_name after do_patch before do_configure