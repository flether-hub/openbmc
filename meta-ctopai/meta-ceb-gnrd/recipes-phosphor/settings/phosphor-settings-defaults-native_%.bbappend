FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

# The generic OpenBMC default is AlwaysOff. CEB-GNRD must restore the
# previous power state after an AC or BMC restart.
do_install:append:ceb-gnrd() {
    sed -i \
        's/Default: RestorePolicy::Policy::AlwaysOff/Default: RestorePolicy::Policy::AlwaysOn/g' \
        ${D}${settings_datadir}/defaults.yaml
}
