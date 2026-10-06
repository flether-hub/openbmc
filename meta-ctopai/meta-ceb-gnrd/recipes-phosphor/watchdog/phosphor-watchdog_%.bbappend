FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

# x86-power-control does not activate the OpenPOWER host-startmin target.
# Keep the IPMI watchdog provider alive independently of host power state.
SYSTEMD_OVERRIDE:${PN}:remove:ceb-gnrd = "poweron.conf:phosphor-watchdog@poweron.service.d/poweron.conf"
SYSTEMD_LINK:${PN}:ceb-gnrd = ""
SYSTEMD_SERVICE:${PN}:ceb-gnrd = " \
    phosphor-watchdog.service \
    phosphor-watchdog-host-reset.service \
    phosphor-watchdog-host-poweroff.service \
    phosphor-watchdog-host-cycle.service \
    "
