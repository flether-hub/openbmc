FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://power-config-host0.json \
    file://0001-ceb-gnrd-add-force-power-button-off-method.patch \
    file://0002-ceb-gnrd-own-bus-name-for-the-exported-buttons.patch \
    file://0003-ceb-gnrd-apply-power-restore-only-on-ac-boot.patch \
    file://0004-ceb-gnrd-log-dc-events-on-chassis-transitions.patch \
    file://0005-ceb-gnrd-report-forced-warm-reset-state.patch \
    file://0006-ceb-gnrd-block-host-start-during-firmware-programming.patch \
    file://0007-ceb-gnrd-ac-restore-power-good-timeout.patch \
    file://0008-ceb-gnrd-resume-pending-ac-restore.patch \
    "

EXTRA_OEMESON:append = " \
    -Dchassis-system-reset=enabled \
    "

do_install:append() {
    install -d ${D}${datadir}/x86-power-control
    install -m 0644 ${UNPACKDIR}/power-config-host0.json \
        ${D}${datadir}/x86-power-control/power-config-host0.json
}

FILES:${PN}:append = " ${datadir}/x86-power-control/power-config-host0.json"
