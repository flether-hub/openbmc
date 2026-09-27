FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-limit-webui-languages.patch \
    file://0002-ceb-gnrd-add-simplified-chinese-locale.patch \
    file://0003-ceb-gnrd-add-fan-control-page.patch \
    file://zh-CN.json \
"

# The small locale patch above provides the build-time key registration.  The
# complete board locale replaces it after patching so every existing page has
# Chinese text instead of falling back to English.
do_configure:append:ceb-gnrd() {
    install -Dm0644 ${UNPACKDIR}/zh-CN.json ${S}/src/locales/zh-CN.json
}
