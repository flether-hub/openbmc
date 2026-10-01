# The fan control page stores its persistence option through the D-Bus REST API.
PACKAGECONFIG:append:ceb-gnrd = " dbus-rest"

# The web "Dumps" page (BMC dump) uses the Redfish Dump log service.  The recipe
# only passes -Dredfish-dump-log=enabled when this PACKAGECONFIG is selected;
# without it the Dump routes are not built and the page has no backend.
PACKAGECONFIG:append:ceb-gnrd = " redfish-dump-log"
