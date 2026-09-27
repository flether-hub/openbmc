# Keep the Xeon 6 sensor applications enabled even if the upstream default
# PACKAGECONFIG changes.  Hardware paths and names are supplied later by
# Entity-Manager/dbus-sensors configuration once the schematic is available.
PACKAGECONFIG:append:ceb-gnrd = " \
    exitairtempsensor \
    fansensor \
    hwmontempsensor \
    intelcpusensor \
    intrusionsensor \
    psusensor \
    "
