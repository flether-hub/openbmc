# ipmitool shows the Manufacturer Name of "mc info" by looking the ID up in the
# IANA enterprise number file under ${datadir}/misc.  Add the CEB-GNRD entry to
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
