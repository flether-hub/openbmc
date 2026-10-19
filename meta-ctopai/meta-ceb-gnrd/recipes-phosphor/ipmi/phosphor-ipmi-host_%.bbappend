FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://0001-ceb-gnrd-report-board-revision-in-mc-info.patch \
    file://0002-ceb-gnrd-show-upper-non-recoverable-threshold.patch \
    file://0003-ceb-gnrd-fru-area-is-the-whole-eeprom.patch \
    file://0004-ceb-gnrd-ipmi-version-and-system-guid.patch \
    file://0005-ceb-gnrd-compatible-chassis-and-optional-vr.patch \
    file://0006-ceb-gnrd-platform-event-channel-and-metadata.patch \
    "

# The patch adds cebGnrdAux(); route the Get Device ID reply through it with a
# single-line substitution so it does not depend on multi-line patch context.

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
SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-wait-sensors.conf file://ceb-gnrd-wait-sensors.sh"
do_install:append:ceb-gnrd() {
    install -d ${D}${systemd_system_unitdir}/phosphor-ipmi-host.service.d
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-wait-sensors.conf \
        ${D}${systemd_system_unitdir}/phosphor-ipmi-host.service.d/10-ceb-gnrd-wait-sensors.conf
    install -D -m 0755 ${UNPACKDIR}/ceb-gnrd-wait-sensors.sh \
        ${D}${libexecdir}/ceb-gnrd-wait-sensors.sh
}
FILES:${PN}:append:ceb-gnrd = " ${systemd_system_unitdir}/phosphor-ipmi-host.service.d ${libexecdir}/ceb-gnrd-wait-sensors.sh"

# Platform-event persistence uses the board SEL logger extension.
RDEPENDS:${PN}:append:ceb-gnrd = " phosphor-sel-logger"

# Board front-panel buttons cannot be masked by the BMC.
SRC_URI:append:ceb-gnrd = " file://0007-ceb-gnrd-report-front-panel-masking-unsupported.patch"

# Keep live UNR status and event masks consistent with the exposed thresholds.
SRC_URI:append:ceb-gnrd = " file://0008-ceb-gnrd-report-live-non-recoverable-alarms.patch"

# Aggregate temperature thresholds are reported but cannot be changed by IPMI.
SRC_URI:append:ceb-gnrd = " file://0009-ceb-gnrd-read-only-aggregate-thresholds.patch"
