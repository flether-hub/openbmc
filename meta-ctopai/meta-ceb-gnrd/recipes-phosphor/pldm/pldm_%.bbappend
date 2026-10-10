# Temporarily stop PLDM until the board's host EID and BIOS configuration
# are available. Keep the package installed so the change is reversible.
SYSTEMD_AUTO_ENABLE:${PN}:ceb-gnrd = "disable"

# Disabling boot enablement alone is insufficient: the upstream postinst
# also links soft-off into host shutdown and warm-reboot targets. Persistent
# masks prevent these targets and D-Bus activation from starting either unit.
do_install:append:ceb-gnrd() {
    install -d ${D}${sysconfdir}/systemd/system
    ln -snf /dev/null ${D}${sysconfdir}/systemd/system/pldmd.service
    ln -snf /dev/null ${D}${sysconfdir}/systemd/system/pldmSoftPowerOff.service
}

FILES:${PN}:append:ceb-gnrd = " \
    ${sysconfdir}/systemd/system/pldmd.service \
    ${sysconfdir}/systemd/system/pldmSoftPowerOff.service \
    "
