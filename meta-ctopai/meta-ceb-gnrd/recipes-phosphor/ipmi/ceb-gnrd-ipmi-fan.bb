SUMMARY = "CEB-GNRD OEM IPMI fan control commands"
DESCRIPTION = "OEM IPMI commands (netfn 0x30, cmd 0x01 get, 0x02 set) that read and change the fan control mode.  They forward to the ceb-gnrd-fan-settings D-Bus service."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

DEPENDS += "phosphor-ipmi-host phosphor-logging sdbusplus boost"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://ceb-gnrd-ipmi-fan/meson.build \
    file://ceb-gnrd-ipmi-fan/fan_oem.cpp \
    "
S = "${UNPACKDIR}/ceb-gnrd-ipmi-fan"

inherit meson pkgconfig
inherit obmc-phosphor-ipmiprovider-symlink

# The commands need the service they forward to.
RDEPENDS:${PN} += "ceb-gnrd-fan-settings"

FILES:${PN}:append = " ${libdir}/ipmid-providers/lib*${SOLIBS}"
FILES:${PN}:append = " ${libdir}/host-ipmid/lib*${SOLIBS}"
FILES:${PN}:append = " ${libdir}/net-ipmid/lib*${SOLIBS}"
FILES:${PN}-dev:append = " ${libdir}/ipmid-providers/lib*${SOLIBSDEV} ${libdir}/ipmid-providers/*.la"

# Load the library in both ipmid (KCS) and netipmid (LAN).
HOSTIPMI_PROVIDER_LIBRARY += "libcebgnrdfancmd.so"
NETIPMI_PROVIDER_LIBRARY += "libcebgnrdfancmd.so"