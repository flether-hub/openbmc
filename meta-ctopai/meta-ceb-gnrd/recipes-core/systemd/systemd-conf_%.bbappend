FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-eth0.network file://20-ceb-gnrd-eth1-ncsi.network"
FILES:${PN}:append:ceb-gnrd = " ${sysconfdir}/systemd/network/00-bmc-eth0.network ${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network"

do_install:append:ceb-gnrd() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-eth0.network \
        ${D}${sysconfdir}/systemd/network/00-bmc-eth0.network
    install -m 0644 ${UNPACKDIR}/20-ceb-gnrd-eth1-ncsi.network \
        ${D}${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network
}
