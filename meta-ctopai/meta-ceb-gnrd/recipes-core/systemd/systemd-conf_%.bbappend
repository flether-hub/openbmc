FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-eth0.network"
FILES:${PN}:append:ceb-gnrd = " ${sysconfdir}/systemd/network/00-bmc-eth0.network"

do_install:append:ceb-gnrd() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-eth0.network \
        ${D}${sysconfdir}/systemd/network/00-bmc-eth0.network
}
