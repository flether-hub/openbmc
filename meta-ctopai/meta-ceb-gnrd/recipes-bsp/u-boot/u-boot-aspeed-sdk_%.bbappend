FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://ast2600-ceb-gnrd.dts"

do_configure:append:ceb-gnrd() {
	install -Dm 0644 ${UNPACKDIR}/ast2600-ceb-gnrd.dts \
		${S}/arch/arm/dts/ast2600-ceb-gnrd.dts

	# DEVICE_TREE only selects the board; the .dtb must also be registered in
	# arch/arm/dts/Makefile, ahead of the first "targets +=" line.
	if ! grep -q 'ast2600-ceb-gnrd.dtb' ${S}/arch/arm/dts/Makefile; then
		sed -i '0,/^targets += /s//dtb-y += ast2600-ceb-gnrd.dtb\n&/' \
			${S}/arch/arm/dts/Makefile
	fi
	grep -q 'ast2600-ceb-gnrd.dtb' ${S}/arch/arm/dts/Makefile || \
		bbfatal "arch/arm/dts/Makefile: could not register ast2600-ceb-gnrd.dtb"
}
