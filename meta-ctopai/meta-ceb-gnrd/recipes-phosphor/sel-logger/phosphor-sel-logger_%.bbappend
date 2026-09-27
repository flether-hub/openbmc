# Enable the standard SEL event producers required by the managed Xeon host.
# The logger itself remains hardware-neutral; board-specific callouts and
# sensor paths belong in Entity-Manager/dbus-sensors configuration later.
PACKAGECONFIG:append:ceb-gnrd = " \
    log-threshold \
    log-host \
    log-watchdog \
    log-alarm \
    "

# Required for IPMI Watchdog 2 expiration records, including BIOS FRB2 and
# OS-load diagnostics.
RDEPENDS:${PN}:append:ceb-gnrd = " phosphor-watchdog "
