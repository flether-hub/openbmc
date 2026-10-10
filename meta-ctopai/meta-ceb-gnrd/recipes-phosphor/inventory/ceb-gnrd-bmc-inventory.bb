SUMMARY = "CEB-GNRD BMC inventory and stable UUID"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit allarch systemd

SRC_URI = " \
    file://ceb-gnrd-bmc-inventory.py \
    file://ceb-gnrd-bmc-inventory.service \
    file://com.ctopai.CebGnrd.BmcInventory.conf \
    file://ceb-gnrd-wait-bmc-inventory.sh \
    file://10-ceb-gnrd-bmc-inventory.conf \
"
S = "${UNPACKDIR}"
SYSTEMD_SERVICE:${PN} = "ceb-gnrd-bmc-inventory.service"
SYSTEMD_AUTO_ENABLE = "enable"

# dbus-fast imports XML and urllib. systemd ships busctl and systemd-id128.
RDEPENDS:${PN} = "python3-core python3-asyncio python3-dbus-fast python3-xml python3-netclient python3-logging python3-threading systemd"

do_install() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-bmc-inventory.py ${D}${libexecdir}/ceb-gnrd-bmc-inventory.py
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-wait-bmc-inventory.sh ${D}${libexecdir}/ceb-gnrd-wait-bmc-inventory.sh
    install -Dm0644 ${UNPACKDIR}/ceb-gnrd-bmc-inventory.service ${D}${systemd_system_unitdir}/ceb-gnrd-bmc-inventory.service
    install -Dm0644 ${UNPACKDIR}/com.ctopai.CebGnrd.BmcInventory.conf ${D}${datadir}/dbus-1/system.d/com.ctopai.CebGnrd.BmcInventory.conf
    for unit in phosphor-health-monitor.service xyz.openbmc_project.Software.BMC.Updater.service; do
        install -Dm0644 ${UNPACKDIR}/10-ceb-gnrd-bmc-inventory.conf ${D}${systemd_system_unitdir}/$unit.d/10-ceb-gnrd-bmc-inventory.conf
    done
}

FILES:${PN} += "${libexecdir} ${systemd_system_unitdir} ${datadir}/dbus-1/system.d"
