SUMMARY = "CEB-GNRD functional check and log collection script"
DESCRIPTION = "ceb-gnrd-check runs on the BMC, prints PASS/FAIL for the board functions (services, sensors, IPMI, fan OEM commands, Redfish, RTC, flash layout) and bundles the logs in /tmp/ceb-gnrd-check.tar.gz."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://ceb-gnrd-check.sh"

S = "${UNPACKDIR}"

# The script only uses BusyBox sh plus the tools below.
RDEPENDS:${PN} = "ipmitool curl"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-check.sh ${D}${bindir}/ceb-gnrd-check
}