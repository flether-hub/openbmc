FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable PECI and other supported kernel options for Intel host integration.
# The pinned kernel does not yet include an AST2600 eSPI controller driver; the
# first patch adds it (driver, Kconfig and Makefile entries).
SRC_URI:append = " \
        file://espi-peci.cfg \
        file://aspeed-ceb-gnrd.dts \
        file://0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch \
        file://0002-hwmon-add-AST2600-chassis-intrusion-driver.patch \
        file://0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch \
        file://0004-pmbus-ratelimit-optional-device-probe-message.patch \
        file://0005-usb-gadget-hid-classify-endpoint-shutdown.patch \
        "

# The board device tree is a new file; the dtb is built through KERNEL_DEVICETREE.
do_configure:append() {
    install -Dm0644 ${UNPACKDIR}/aspeed-ceb-gnrd.dts \
        ${S}/arch/arm/boot/dts/aspeed/aspeed-ceb-gnrd.dts
}
