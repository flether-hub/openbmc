FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-post-history-warm-boot-cycle.patch file://ceb-gnrd-post-history-limit.py file://60-ceb-gnrd-post-history.conf"
EXTRA_OEMESON:append:ceb-gnrd = " -Dmax-boot-cycle-count=2 -Dmax-post-code-size-per-cycle=512"
RDEPENDS:${PN}:append:ceb-gnrd = " python3-core"

do_install:append:ceb-gnrd() {
    install -Dm0755 ${UNPACKDIR}/ceb-gnrd-post-history-limit.py ${D}${libexecdir}/ceb-gnrd-post-history-limit
    install -Dm0644 ${UNPACKDIR}/60-ceb-gnrd-post-history.conf ${D}${systemd_system_unitdir}/xyz.openbmc_project.State.Boot.PostCode@.service.d/60-ceb-gnrd-post-history.conf
}
FILES:${PN}:append:ceb-gnrd = " ${libexecdir}/ceb-gnrd-post-history-limit ${systemd_system_unitdir}/xyz.openbmc_project.State.Boot.PostCode@.service.d/60-ceb-gnrd-post-history.conf"
