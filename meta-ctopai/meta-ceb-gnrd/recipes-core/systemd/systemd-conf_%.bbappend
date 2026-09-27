FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://10-ceb-gnrd-eth0.network"

do_install:append() {
    install -d ${D}${systemd_unitdir}/network
    install -m 0644 ${WORKDIR}/10-ceb-gnrd-eth0.network ${D}${systemd_unitdir}/network/10-ceb-gnrd-eth0.network
}
