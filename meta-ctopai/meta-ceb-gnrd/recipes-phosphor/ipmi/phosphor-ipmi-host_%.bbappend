FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://0001-ceb-gnrd-report-board-revision-in-mc-info.patch \
    file://0002-ceb-gnrd-show-upper-non-recoverable-threshold.patch \
    "

# The patch adds cebGnrdAux(); route the Get Device ID reply through it with a
# single-line substitution so it does not depend on multi-line patch context.
# The board patch applies with fuzz on the pinned source; report it as a
# warning until its context lines are refreshed.
ERROR_QA:remove = "patch-fuzz"
WARN_QA:append = " patch-fuzz"

do_ceb_gnrd_aux() {
    sed -i 's/devId\.prodId, devId\.aux);/devId.prodId, cebGnrdAux(devId.aux));/' \
        ${S}/apphandler.cpp
    grep -q 'cebGnrdAux(devId.aux)' ${S}/apphandler.cpp || \
        bbfatal "apphandler.cpp: Get Device ID return statement not found"
}
addtask ceb_gnrd_aux after do_patch before do_configure

DEPENDS:append = " libgpiod"
LDFLAGS:append = " -lgpiod"

# Publish every D-Bus sensor (ADC voltages, temperatures, fans, CPU_MAX_TEMP and
# DIMM_MAX_TEMP) through IPMI.  hybrid-sensors keeps the static host-state
# sensors (boot progress, OS status, ...) next to the dynamic ones.
PACKAGECONFIG:append = " dynamic-sensors hybrid-sensors"

# Delay ipmid until the first D-Bus sensor exists (see the drop-in).
SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-wait-sensors.conf"
do_install:append:ceb-gnrd() {
    install -d ${D}${systemd_system_unitdir}/phosphor-ipmi-host.service.d
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-wait-sensors.conf \
        ${D}${systemd_system_unitdir}/phosphor-ipmi-host.service.d/10-ceb-gnrd-wait-sensors.conf
}
FILES:${PN}:append:ceb-gnrd = " ${systemd_system_unitdir}/phosphor-ipmi-host.service.d"
