FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:${THISDIR}/../state/files:"

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
    file://0040-ceb-gnrd-cpld-firmware-update.patch \
    file://0041-ceb-gnrd-ami-post-code-descriptions.patch \
    file://0042-ceb-gnrd-post-code-sequence-context.patch \
    file://0043-ceb-gnrd-post-code-concise-descriptions.patch \
    file://0044-ceb-gnrd-post-code-export-json-array.patch \
    file://0045-ceb-gnrd-firmware-upload-hints.patch \
    file://0046-ceb-gnrd-post-code-source-context.patch \
    file://0047-ceb-gnrd-firmware-hints-above-upload.patch \
    file://0048-ceb-gnrd-date-time-input-alignment.patch \
    file://0049-ceb-gnrd-post-code-latest-cycle-only.patch \
    file://0050-ceb-gnrd-firmware-upload-mutual-exclusion.patch \
    file://0051-ceb-gnrd-firmware-upload-labels.patch \
    file://0052-ceb-gnrd-cpld-update-firmware-heading.patch \
    file://0053-ceb-gnrd-overview-existing-build-info.patch \
    file://0054-ceb-gnrd-bios-missing-version-na.patch \
    file://0055-ceb-gnrd-hide-overview-source-version.patch \
    file://0056-ceb-gnrd-virtual-media-survives-navigation.patch \
    file://0057-ceb-gnrd-consumed-boot-override.patch \
    file://0058-ceb-gnrd-fix-event-export-and-fan-load-status.patch \
    file://0059-ceb-gnrd-fan-speed-ten-percent-steps.patch \
    file://0060-ceb-gnrd-vm-close-and-cpld-stage-timeouts.patch \
    file://0061-ceb-gnrd-show-custom-and-mixed-fan-settings.patch \
    file://0062-ceb-gnrd-read-only-mac-address.patch \
    file://0063-ceb-gnrd-project-post-code-definitions.patch \
    file://0064-ceb-gnrd-initialize-recovered-fan-settings.patch \
    file://0065-ceb-gnrd-load-all-event-log-pages.patch \
    file://ami-aptio-v-post-codes.json \
    file://zh-CN.json \
"

# The small locale patch above provides the build-time key registration.  The
# complete board locale replaces it after patching so every existing page has
# Chinese text instead of falling back to English.
do_configure:append:ceb-gnrd() {
    # File-backed event logs have no Resolved property/PATCH operation.
    printf '\nVITE_EVENT_LOGS_TOGGLE_BUTTON_DISABLED=true\n' >> ${S}/.env.production.local
    install -Dm0644 ${UNPACKDIR}/ami-aptio-v-post-codes.json ${S}/src/data/amiAptioVPostCodes.json
    install -Dm0644 ${UNPACKDIR}/zh-CN.json ${S}/src/locales/zh-CN.json
}
