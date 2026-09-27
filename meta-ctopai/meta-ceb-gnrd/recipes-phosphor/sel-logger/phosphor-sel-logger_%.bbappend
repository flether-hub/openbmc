# Enable the standard SEL event producers required by the managed Xeon host.
# The logger itself remains hardware-neutral; board-specific callouts and
# sensor paths belong in Entity-Manager/dbus-sensors configuration later.
PACKAGECONFIG:append:ceb-gnrd = " \
    log-threshold \
    log-host \
    log-watchdog \
    log-alarm \
    "
