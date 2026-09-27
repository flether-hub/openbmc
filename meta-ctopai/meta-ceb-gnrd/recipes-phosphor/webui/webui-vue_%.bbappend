FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-limit-webui-languages.patch \
    file://0002-ceb-gnrd-add-simplified-chinese-locale.patch \
"
