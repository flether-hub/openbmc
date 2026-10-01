FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://0001-ceb-gnrd-report-board-revision-in-mc-info.patch"

# The patch adds cebGnrdAux(); route the Get Device ID reply through it with a
# single-line substitution so it does not depend on multi-line patch context.
do_patch:append() {
    sed -i 's/devId\.prodId, devId\.aux);/devId.prodId, cebGnrdAux(devId.aux));/' \
        ${S}/apphandler.cpp
    grep -q 'cebGnrdAux(devId.aux)' ${S}/apphandler.cpp || \
        bbfatal "apphandler.cpp: Get Device ID return statement not found"
}

DEPENDS:append = " libgpiod"
LDFLAGS:append = " -lgpiod"
