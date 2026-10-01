# Enable the standard SEL event producers required by the managed Xeon host.
# The logger itself remains hardware-neutral; board-specific callouts and
# sensor paths belong in Entity-Manager/dbus-sensors configuration later.
PACKAGECONFIG:append:ceb-gnrd = " \
    log-threshold \
    log-host \
    log-watchdog \
    log-alarm \
    "

# Entity-Manager Severity 4 thresholds (voltages) and the CPU/DIMM maximum
# temperature sensors use the HardShutdown threshold interface; log those as
# upper/lower non-recoverable SEL events as well.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-log-non-recoverable-threshold-events.patch"

# Required for IPMI Watchdog 2 expiration records, including BIOS FRB2 and
# OS-load diagnostics.
RDEPENDS:${PN}:append:ceb-gnrd = " phosphor-watchdog "
