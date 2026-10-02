# The fan control page stores its persistence option through the D-Bus REST API.
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
