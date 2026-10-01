SUMMARY = "CEB-GNRD IPMI sensor definitions"
DESCRIPTION = "Static IPMI sensors for the single-socket CEB-GNRD: host boot progress, OS status, boot attempts and PSU redundancy. The generic per-core CPU and DIMM entries of the default config are dropped; hardware sensors come from dbus-sensors."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"
PROVIDES += "virtual/phosphor-ipmi-sensor-inventory"
PR = "r1"

FILESEXTRAPATHS:prepend := "${THISDIR}/ceb-gnrd-ipmi-sensors:"
SRC_URI += "file://config.yaml"

S = "${UNPACKDIR}"

inherit phosphor-ipmi-host
inherit native

do_install() {
    DEST=${D}${sensor_datadir}
    install -d ${DEST}
    install ${S}/config.yaml ${DEST}/sensor.yaml
}