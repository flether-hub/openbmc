FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable PECI and other supported kernel options for Intel host integration.
# The pinned kernel does not yet include an AST2600 eSPI controller driver.
SRC_URI:append = " \
        file://espi-peci.cfg \
        file://aspeed-ceb-gnrd.dts \
        file://0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch \
        file://0002-hwmon-add-AST2600-chassis-intrusion-driver.patch \
        "

# The eSPI patch only adds the Kconfig entry and the driver source; hook the
# object into Kbuild here so the patch does not depend on Makefile context.
do_configure:append() {
    install -Dm0644 ${UNPACKDIR}/aspeed-ceb-gnrd.dts \
        ${S}/arch/arm/boot/dts/aspeed/aspeed-ceb-gnrd.dts
    if ! grep -q 'aspeed-espi-peripheral.o' ${S}/drivers/soc/aspeed/Makefile; then
        printf '%s\n' 'obj-$(CONFIG_ASPEED_ESPI) += aspeed-espi-peripheral.o' \
            >> ${S}/drivers/soc/aspeed/Makefile
    fi
}
