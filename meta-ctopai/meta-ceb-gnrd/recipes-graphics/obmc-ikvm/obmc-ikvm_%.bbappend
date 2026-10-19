FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-initial-framebuffer-1024x768.patch \
    "
