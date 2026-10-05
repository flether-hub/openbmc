FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-limit-webui-languages.patch \
    file://0002-ceb-gnrd-add-simplified-chinese-locale.patch \
    file://0003-ceb-gnrd-add-fan-control-page.patch \
    file://0004-ceb-gnrd-remove-resource-management-power.patch \
    file://0006-ceb-gnrd-kvm-full-screen.patch \
    file://0007-ceb-gnrd-factory-reset-bmc-only.patch \
    file://0008-ceb-gnrd-inventory-supported-tables-only.patch \
    file://0009-ceb-gnrd-remove-overview-power-card.patch \
    file://0010-ceb-gnrd-firmware-single-bank.patch \
    file://0011-ceb-gnrd-dumps-bmc-only.patch \
    file://0012-ceb-gnrd-policies-remove-vtpm-rtad.patch \
    file://0013-ceb-gnrd-firmware-update-progress.patch \
    file://0014-ceb-gnrd-firmware-cards-side-by-side.patch \
    file://0015-ceb-gnrd-sensors-discrete-table.patch \
    file://0016-ceb-gnrd-post-codes-newest-first.patch \
    file://0017-ceb-gnrd-sensors-pagination.patch \
    file://0018-ceb-gnrd-firmware-progress-survives-page-change.patch \
    file://0019-ceb-gnrd-factory-reset-bmc-wording.patch \
    file://0020-ceb-gnrd-overview-firmware-card.patch \
    file://0021-ceb-gnrd-refresh-server-power-operation-state.patch \
    file://zh-CN.json \
"

# The small locale patch above provides the build-time key registration.  The
# complete board locale replaces it after patching so every existing page has
# Chinese text instead of falling back to English.
do_configure:append:ceb-gnrd() {
    install -Dm0644 ${UNPACKDIR}/zh-CN.json ${S}/src/locales/zh-CN.json
}
