FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://ast2600-ceb-gnrd.dts"

do_configure:append:ceb-gnrd() {
	install -Dm 0644 ${UNPACKDIR}/ast2600-ceb-gnrd.dts \
		${S}/arch/arm/dts/ast2600-ceb-gnrd.dts
}
