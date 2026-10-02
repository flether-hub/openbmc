SUMMARY = "CEB-GNRD BMC health: standard service recovery and watchdog reset logging"
DESCRIPTION = "Installs a systemd drop-in (Restart=always, start limit, OnFailure=obmc-bmc-service-quiesce) for the critical BMC services, and ceb-gnrd-wdt-reset-log, which writes a SEL record when the BMC was restarted by the hardware watchdog without a clean shutdown."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://10-ceb-gnrd-restart.conf \
    file://ceb-gnrd-wdt-reset-log.sh \
    file://ceb-gnrd-wdt-reset-log.service \
    file://ceb-gnrd-quiesce-reboot-limit.sh \
    file://10-ceb-gnrd-reboot-limit.conf \
    file://ceb-gnrd-quiesce-reboot-clear.service \
    file://ceb-gnrd-quiesce-reboot-clear.timer \
    "

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "ceb-gnrd-wdt-reset-log.service ceb-gnrd-quiesce-reboot-clear.timer"
SYSTEMD_AUTO_ENABLE = "enable"

# Units that get the restart / quiesce drop-in.  The first four are upstream
# services (none of them pings the systemd watchdog, so WatchdogSec= cannot be
# used for them); the last three are this layer's own services, which send
# READY=1 and WATCHDOG=1 themselves (Type=notify, WatchdogSec= in their units).
RESTART_UNITS = " \
    xyz.openbmc_project.ObjectMapper.service \
    xyz.openbmc_project.EntityManager.service \
    bmcweb.service \
    phosphor-ipmi-host.service \
    ceb-gnrd-fan-settings.service \
    ceb-gnrd-temp-max.service \
    ceb-gnrd-alert-led.service \
    "

do_install() {
    install -d ${D}${libexecdir} ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-wdt-reset-log.sh ${D}${libexecdir}/ceb-gnrd-wdt-reset-log.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-wdt-reset-log.service ${D}${systemd_system_unitdir}/ceb-gnrd-wdt-reset-log.service
    # at most 3 automatic reboots in a row after the BMC was quiesced
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-quiesce-reboot-limit.sh ${D}${libexecdir}/ceb-gnrd-quiesce-reboot-limit.sh
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-quiesce-reboot-clear.service ${D}${systemd_system_unitdir}/ceb-gnrd-quiesce-reboot-clear.service
    install -m 0644 ${UNPACKDIR}/ceb-gnrd-quiesce-reboot-clear.timer ${D}${systemd_system_unitdir}/ceb-gnrd-quiesce-reboot-clear.timer
    install -d ${D}${systemd_system_unitdir}/phosphor-bmc-quiesce-reboot.service.d
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-reboot-limit.conf \
        ${D}${systemd_system_unitdir}/phosphor-bmc-quiesce-reboot.service.d/10-ceb-gnrd-reboot-limit.conf
    for unit in ${RESTART_UNITS}; do
        install -d ${D}${systemd_system_unitdir}/${unit}.d
        install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-restart.conf \
            ${D}${systemd_system_unitdir}/${unit}.d/10-ceb-gnrd-restart.conf
    done
}

FILES:${PN} += " \
    ${libexecdir}/ceb-gnrd-wdt-reset-log.sh \
    ${libexecdir}/ceb-gnrd-quiesce-reboot-limit.sh \
    ${systemd_system_unitdir}/ceb-gnrd-quiesce-reboot-clear.service \
    ${systemd_system_unitdir}/ceb-gnrd-quiesce-reboot-clear.timer \
    ${systemd_system_unitdir}/ceb-gnrd-wdt-reset-log.service \
    ${systemd_system_unitdir}/*.service.d \
    "
