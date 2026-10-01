FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://0001-ceb-gnrd-report-board-revision-in-mc-info.patch"

DEPENDS:append = " libgpiod"
LDFLAGS:append = " -lgpiod"
