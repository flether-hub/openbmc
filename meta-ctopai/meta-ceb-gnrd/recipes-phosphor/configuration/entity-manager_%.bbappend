FILESEXTRAPATHS:prepend := "${THISDIR}/entity-manager:"

# The patch lets WriteFru take an image as large as the EEPROM (limit was 512).
SRC_URI:append:ceb-gnrd = " \
    file://ceb-gnrd.json \
    file://0001-ceb-gnrd-fru-device-allow-eeprom-sized-write.patch \
    "

do_install:append:ceb-gnrd() {
    install -D -m 0644 ${UNPACKDIR}/ceb-gnrd.json \
        ${D}${datadir}/entity-manager/configurations/ceb-gnrd.json
}

FILES:${PN}:append:ceb-gnrd = " \
    ${datadir}/entity-manager/configurations/ceb-gnrd.json \
    "
