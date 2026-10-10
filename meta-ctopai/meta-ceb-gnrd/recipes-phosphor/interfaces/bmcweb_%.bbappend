# The fan control page stores its persistence option through the D-Bus REST API.
FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-delete-single-file-event-log.patch"
SRC_URI:append:ceb-gnrd = " file://0002-ceb-gnrd-async-virtual-media-proxy-cleanup.patch"
SRC_URI:append:ceb-gnrd = " file://0003-ceb-gnrd-virtual-media-receive-backpressure.patch"
SRC_URI:append:ceb-gnrd = " file://0004-ceb-gnrd-report-boot-id-for-update-monitor.patch"
SRC_URI:append:ceb-gnrd = " file://0005-ceb-gnrd-allow-same-origin-kvm-fullscreen.patch"
SRC_URI:append:ceb-gnrd = " file://0006-ceb-gnrd-fix-bmcweb-state-directory.patch"

PACKAGECONFIG:append:ceb-gnrd = " dbus-rest"

# The web "Dumps" page (BMC dump) uses the Redfish Dump log service.  The recipe
# only passes -Dredfish-dump-log=enabled when this PACKAGECONFIG is selected;
# without it the Dump routes are not built and the page has no backend.
PACKAGECONFIG:append:ceb-gnrd = " redfish-dump-log"

# bmcweb defaults to redfish-updateservice-use-dbus=enabled: it then looks for the
# running BMC version under /xyz/openbmc_project/software/bmc/functional and hands
# updates to the xyz.openbmc_project.Software.Update interface.  The phosphor-
# image-updater used here is the classic one: it publishes the version under
# /xyz/openbmc_project/software/functional and takes images dropped in
# /tmp/images, which is what the disabled setting uses.  With the default the web
# firmware page and Redfish Manager FirmwareVersion show no BMC version.
EXTRA_OEMESON:append:ceb-gnrd = " -Dredfish-updateservice-use-dbus=disabled"

# Firmware upload size: bmcweb rejects request bodies larger than http-body-limit
# (default 30 MiB), and the CEB-GNRD update package is bigger (40 MiB rofs plus the
# kernel, about 50 MiB), so the web update failed with "Error starting firmware
# update".  Allow 80 MiB (the full 64 MiB flash image plus headroom).
EXTRA_OEMESON:append:ceb-gnrd = " -Dhttp-body-limit=80"
