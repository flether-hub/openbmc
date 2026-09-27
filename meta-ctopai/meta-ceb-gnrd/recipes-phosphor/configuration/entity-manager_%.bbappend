FILESEXTRAPATHS:prepend := "${THISDIR}/entity-manager:"

SRC_URI:append:ceb-gnrd = " file://ceb-gnrd.json"

do_install:append:ceb-gnrd() {
    install -D -m 0644 ${WORKDIR}/ceb-gnrd.json \
        ${D}${datadir}/entity-manager/configurations/ceb-gnrd.json
}

FILES:${PN}:append:ceb-gnrd = " \
    ${datadir}/entity-manager/configurations/ceb-gnrd.json \
    "
