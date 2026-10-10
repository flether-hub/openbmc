FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

# The patch registers the device tree in arch/arm/dts/Makefile, sets the default
# network values and puts CEB_GNRD_ENV into the default environment.  The device
# tree and the environment header are new files, installed below.
SRC_URI:append:ceb-gnrd = " \
	file://0001-ceb-gnrd-board-device-tree-network-and-environment.patch \
	file://0002-ceb-gnrd-pass-boot-reset-cause-to-linux.patch \
	file://0003-ceb-gnrd-fill-missing-default-mac.patch \
	file://0004-ceb-gnrd-reserve-32m-vga-before-ddr-init.patch \
	file://ast2600-ceb-gnrd.dts \
	file://ceb-gnrd-env.h \
	file://ceb-gnrd-ddr4.cfg \
	file://ceb-gnrd-network.cfg \
	"

do_configure:append:ceb-gnrd() {
	install -Dm 0644 ${UNPACKDIR}/ast2600-ceb-gnrd.dts \
		${S}/arch/arm/dts/ast2600-ceb-gnrd.dts
	install -Dm 0644 ${UNPACKDIR}/ceb-gnrd-env.h \
		${S}/include/configs/ceb-gnrd-env.h
}
