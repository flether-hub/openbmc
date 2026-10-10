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
    file://0022-ceb-gnrd-event-log-explicit-columns.patch \
    file://0023-ceb-gnrd-event-log-actions-heading.patch \
    file://0024-ceb-gnrd-refresh-live-status-pages.patch \
    file://0025-ceb-gnrd-close-virtual-media-websocket-on-stop.patch \
    file://0026-ceb-gnrd-chunk-virtual-media-read-replies.patch \
    file://0027-ceb-gnrd-post-code-table-sort-api.patch \
    file://0028-ceb-gnrd-event-logs-newest-first.patch \
    file://0029-ceb-gnrd-bmc-update-partition-selection.patch \
    file://0030-ceb-gnrd-bmc-update-completion-notification.patch \
    file://0031-ceb-gnrd-sol-source-selection.patch \
    file://0032-ceb-gnrd-kvm-restore-fullscreen-layout.patch \
    file://0033-ceb-gnrd-chassis-intrusion-switch.patch \
    file://0034-ceb-gnrd-timezone-ui-language.patch \
    file://0035-ceb-gnrd-boot-checkpoint-details.patch \
    file://0036-ceb-gnrd-colored-navigation-icons.patch \
    file://0037-ceb-gnrd-refresh-confirmed-time-mode.patch \
    file://0038-ceb-gnrd-colored-openbmc-logos.patch \
    file://0039-ceb-gnrd-responsive-date-time-settings.patch \
    file://zh-CN.json \
"

# The small locale patch above provides the build-time key registration.  The
# complete board locale replaces it after patching so every existing page has
# Chinese text instead of falling back to English.
do_configure:append:ceb-gnrd() {
    # File-backed event logs have no Resolved property/PATCH operation.
    printf '\nVITE_EVENT_LOGS_TOGGLE_BUTTON_DISABLED=true\n' >> ${S}/.env.production.local
    install -Dm0644 ${UNPACKDIR}/zh-CN.json ${S}/src/locales/zh-CN.json
}
