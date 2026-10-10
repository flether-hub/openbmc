FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " file://ceb-gnrd-clear-network-mac.sh file://20-ceb-gnrd-boot-mac.conf"
FILES:${PN}:append:ceb-gnrd = " ${libexecdir}/ceb-gnrd-clear-network-mac.sh ${sysconfdir}/systemd/system/systemd-networkd.service.d/20-ceb-gnrd-boot-mac.conf"

do_install:append:ceb-gnrd() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-clear-network-mac.sh ${D}${libexecdir}/ceb-gnrd-clear-network-mac.sh
    install -d ${D}${sysconfdir}/systemd/system/systemd-networkd.service.d
    sed 's|/usr/libexec/|${libexecdir}/|g' ${UNPACKDIR}/20-ceb-gnrd-boot-mac.conf \
        > ${D}${sysconfdir}/systemd/system/systemd-networkd.service.d/20-ceb-gnrd-boot-mac.conf
    chmod 0644 ${D}${sysconfdir}/systemd/system/systemd-networkd.service.d/20-ceb-gnrd-boot-mac.conf
}

SRC_URI:append:ceb-gnrd = " file://10-ceb-gnrd-eth0.network file://20-ceb-gnrd-eth1-ncsi.network file://40-hardware-watchdog.conf file://50-ceb-gnrd-console.conf"
FILES:${PN}:append:ceb-gnrd = " ${sysconfdir}/systemd/network/00-bmc-eth0.network ${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network ${sysconfdir}/systemd/system.conf.d/40-hardware-watchdog.conf ${sysconfdir}/sysctl.d/50-ceb-gnrd-console.conf"

do_install:append:ceb-gnrd() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-ceb-gnrd-eth0.network \
        ${D}${sysconfdir}/systemd/network/00-bmc-eth0.network
    install -m 0644 ${UNPACKDIR}/20-ceb-gnrd-eth1-ncsi.network \
        ${D}${sysconfdir}/systemd/network/10-bmc-eth1-ncsi.network

    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${UNPACKDIR}/40-hardware-watchdog.conf \
        ${D}${sysconfdir}/systemd/system.conf.d/40-hardware-watchdog.conf
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/50-ceb-gnrd-console.conf \
        ${D}${sysconfdir}/sysctl.d/50-ceb-gnrd-console.conf
}

SRC_URI:append:ceb-gnrd = " file://60-ceb-gnrd-journal-limits.conf file://60-ceb-gnrd-coredump-limits.conf file://60-ceb-gnrd-pstore-limits.conf"
FILES:${PN}:append:ceb-gnrd = " ${sysconfdir}/systemd/journald.conf.d/60-ceb-gnrd-journal-limits.conf ${sysconfdir}/systemd/coredump.conf.d/60-ceb-gnrd-coredump-limits.conf ${sysconfdir}/systemd/pstore.conf.d/60-ceb-gnrd-pstore-limits.conf"
do_install:append:ceb-gnrd() {
    install -Dm0644 ${UNPACKDIR}/60-ceb-gnrd-journal-limits.conf ${D}${sysconfdir}/systemd/journald.conf.d/60-ceb-gnrd-journal-limits.conf
    install -Dm0644 ${UNPACKDIR}/60-ceb-gnrd-coredump-limits.conf ${D}${sysconfdir}/systemd/coredump.conf.d/60-ceb-gnrd-coredump-limits.conf
    install -Dm0644 ${UNPACKDIR}/60-ceb-gnrd-pstore-limits.conf ${D}${sysconfdir}/systemd/pstore.conf.d/60-ceb-gnrd-pstore-limits.conf
}
