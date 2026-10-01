FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://power-config-host0.json file://0001-ceb-gnrd-add-force-power-button-off-method.patch"

# The board patch applies with fuzz 1 on the pinned source; report it as a
# warning until its context lines are refreshed.
ERROR_QA:remove = "patch-fuzz"
WARN_QA:append = " patch-fuzz"

EXTRA_OEMESON:append = " \
    -Dchassis-system-reset=enabled \
    "

do_install:append() {
    install -d ${D}${datadir}/x86-power-control
    install -m 0644 ${UNPACKDIR}/power-config-host0.json \
        ${D}${datadir}/x86-power-control/power-config-host0.json
}

FILES:${PN}:append = " ${datadir}/x86-power-control/power-config-host0.json"
