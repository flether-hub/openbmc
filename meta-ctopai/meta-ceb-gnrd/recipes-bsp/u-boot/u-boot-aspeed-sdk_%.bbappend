FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " \
	file://ast2600-ceb-gnrd.dts \
	file://ceb-gnrd-netboot.cfg \
	file://ceb-gnrd-env.h \
	"

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

	# Default network settings: same address as eth0 in Linux
	# (192.168.185.200/24, gateway 192.168.185.1); the TFTP server is
	# 192.168.185.84.  These are plain macros in the common header.
	sed -i \
		-e 's/^\(#define CONFIG_GATEWAYIP[[:space:]]\+\).*/\1192.168.185.1/' \
		-e 's/^\(#define CONFIG_NETMASK[[:space:]]\+\).*/\1255.255.255.0/' \
		-e 's/^\(#define CONFIG_IPADDR[[:space:]]\+\).*/\1192.168.185.200/' \
		-e 's/^\(#define CONFIG_SERVERIP[[:space:]]\+\).*/\1192.168.185.84/' \
		${S}/include/configs/aspeed-common.h
	grep -q 'CONFIG_IPADDR[[:space:]]\+192.168.185.200' ${S}/include/configs/aspeed-common.h || \
		bbfatal "include/configs/aspeed-common.h: could not set the default IP address"

	# Extra default environment variables ("run netupdate").  The board
	# header defines CONFIG_EXTRA_ENV_SETTINGS (loadaddr, bootspi, verify):
	# include our header and concatenate CEB_GNRD_ENV in front of "verify".
	install -Dm 0644 ${UNPACKDIR}/ceb-gnrd-env.h \
		${S}/include/configs/ceb-gnrd-env.h
	envcfg=${S}/include/configs/evb_ast2600a1_spl.h
	if ! grep -q 'ceb-gnrd-env.h' ${envcfg}; then
		sed -i \
			-e 's|^#include <configs/aspeed-common.h>|&\n#include <configs/ceb-gnrd-env.h>|' \
			-e 's|"verify=yes|CEB_GNRD_ENV "verify=yes|' \
			${envcfg}
	fi
	grep -q 'ceb-gnrd-env.h' ${envcfg} && grep -q 'CEB_GNRD_ENV "verify=yes' ${envcfg} || \
		bbfatal "${envcfg}: could not add the CEB-GNRD default environment"
}
