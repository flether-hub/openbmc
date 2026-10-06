SUMMARY = "CEB-GNRD functional check and log collection script"
DESCRIPTION = "Read-only firmware and current QEMU checks for services, sensors, IPMI, FRU, fan ownership, Redfish, eSPI/SOL, USB/NBD/VGA, RTL8211/NC-SI, reset reasons and flash/log budgets. Captures bounded diagnostics in /tmp/ceb-gnrd-check.tar.gz."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# bmc-hw-dump: read-only dump of how the running firmware uses the hardware, run on
# the old vendor firmware and on this one to compare them (sh bmc-hw-dump.sh -h).
SRC_URI = "file://ceb-gnrd-check.sh file://ceb-gnrd-check.py file://bmc-hw-dump.sh"

S = "${UNPACKDIR}"

# Use split standard-library packages rather than the full Python modules set.
RDEPENDS:${PN} = "ipmitool curl python3-core python3-json python3-io python3-netclient python3-resource"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/ceb-gnrd-check.sh ${D}${bindir}/ceb-gnrd-check
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-check.py ${D}${libexecdir}/ceb-gnrd-check.py
    install -m 0755 ${UNPACKDIR}/bmc-hw-dump.sh ${D}${bindir}/bmc-hw-dump
}
