# Enable the standard SEL event producers required by the managed Xeon host.
# The logger itself remains hardware-neutral; board-specific callouts and
# sensor paths belong in Entity-Manager/dbus-sensors configuration later.
PACKAGECONFIG:append:ceb-gnrd = " \
    log-threshold \
    log-host \
    log-watchdog \
    log-alarm \
    "

# The CPU/DIMM maximum temperature sensors publish their upper non-recoverable
# threshold on a private interface, never on HardShutdown (nothing may power the
# system off).  Log its assertions as upper/lower non-recoverable SEL events.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-log-non-recoverable-threshold-events.patch"

# Required for IPMI Watchdog 2 expiration records, including BIOS FRB2 and
# OS-load diagnostics.
RDEPENDS:${PN}:append:ceb-gnrd = " phosphor-watchdog "
