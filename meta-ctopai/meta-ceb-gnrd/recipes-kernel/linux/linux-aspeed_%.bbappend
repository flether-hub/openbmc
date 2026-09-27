FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable eSPI and PECI kernel options for Intel host integration.
SRC_URI:append = " \
        file://espi-peci.cfg \
        file://aspeed-ceb-gnrd.dts \
        "

do_configure:append() {
    install -Dm0644 ${UNPACKDIR}/aspeed-ceb-gnrd.dts \
        ${S}/arch/arm/boot/dts/aspeed/aspeed-ceb-gnrd.dts
}
