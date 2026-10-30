FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable PECI and other supported kernel options for Intel host integration.
# The pinned kernel does not yet include an AST2600 eSPI controller driver; the
# first patch adds it (driver, Kconfig and Makefile entries).
SRC_URI:append = " \
        file://espi-peci.cfg \
        file://aspeed-ceb-gnrd.dts \
        file://ceb-gnrd-jtag.c \
        file://0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch \
        file://0002-hwmon-add-AST2600-chassis-intrusion-driver.patch \
        file://0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch \
        file://0004-pmbus-ratelimit-optional-device-probe-message.patch \
        file://0005-usb-gadget-hid-classify-endpoint-shutdown.patch \
        file://0006-ncsi-accept-initial-deselect-response.patch \
        file://0007-peci-retry-response-in-progress.patch \
        file://0008-hwmon-add-megcrps800-psu-driver.patch \
        file://0009-ncsi-retry-empty-discovery-on-start.patch \
        file://0010-spi-aspeed-select-data-width-for-user-writes.patch \
        file://0011-ncsi-handle-idle-work-and-report-invalid-responses.patch \
        file://0012-spi-nor-detect-board-bios-on-explicit-bind.patch \
        file://0013-ncsi-retry-mandatory-channel-configuration.patch \
        file://0014-ftgmac100-report-ncsi-data-path-readiness.patch \
        file://0015-ncsi-refresh-link-after-cable-status-updates.patch \
        "

do_patch:append() {
    install -m0644 ${UNPACKDIR}/ceb-gnrd-jtag.c ${S}/drivers/misc/ceb-gnrd-jtag.c
    # Only this board enables the private, fixed-width JTAG ABI. Its driver
    # does not change pin levels during boot; output starts on exclusive open.
    if ! grep -q CONFIG_CEB_GNRD_JTAG ${S}/drivers/misc/Makefile; then
        printf '\nobj-$(CONFIG_CEB_GNRD_JTAG) += ceb-gnrd-jtag.o\n' >> ${S}/drivers/misc/Makefile
        printf '\nconfig CEB_GNRD_JTAG\n\tbool "CEB-GNRD dedicated JTAG Master-1"\n\tdepends on ARCH_ASPEED\n' >> ${S}/drivers/misc/Kconfig
    fi
}

# The board device tree is a new file; the dtb is built through KERNEL_DEVICETREE.
do_configure:append() {
    install -Dm0644 ${UNPACKDIR}/aspeed-ceb-gnrd.dts \
        ${S}/arch/arm/boot/dts/aspeed/aspeed-ceb-gnrd.dts
}
