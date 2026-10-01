FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://power-config-host0.json file://0001-ceb-gnrd-add-force-power-button-off-method.patch"

EXTRA_OEMESON:append = " \
    -Dbutton-passthrough=enabled \
    -Dchassis-system-reset=enabled \
    "

do_install:append() {
    install -d ${D}${datadir}/x86-power-control
    install -m 0644 ${UNPACKDIR}/power-config-host0.json \
        ${D}${datadir}/x86-power-control/power-config-host0.json
}

FILES:${PN}:append = " ${datadir}/x86-power-control/power-config-host0.json"
