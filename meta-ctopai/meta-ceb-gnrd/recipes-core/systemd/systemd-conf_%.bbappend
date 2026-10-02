FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-eth0.network file://20-ceb-gnrd-eth1-ncsi.network file://50-ceb-gnrd-watchdog.conf"
FILES:${PN}:append:ceb-gnrd = " ${sysconfdir}/systemd/network/00-bmc-eth0.network ${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network ${sysconfdir}/systemd/system.conf.d/50-ceb-gnrd-watchdog.conf"

do_install:append:ceb-gnrd() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-eth0.network \
        ${D}${sysconfdir}/systemd/network/00-bmc-eth0.network
    install -m 0644 ${UNPACKDIR}/20-ceb-gnrd-eth1-ncsi.network \
        ${D}${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network

    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${UNPACKDIR}/50-ceb-gnrd-watchdog.conf \
        ${D}${sysconfdir}/systemd/system.conf.d/50-ceb-gnrd-watchdog.conf
}
