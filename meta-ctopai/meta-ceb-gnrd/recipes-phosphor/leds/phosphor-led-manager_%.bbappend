FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The LED group manager reads /etc/phosphor-led-manager/led-group-config.json
# or /usr/share/phosphor-led-manager/led-group-config.json.  Without one it waits
# for an Entity-Manager configuration and never registers on D-Bus (the unit
# then fails with "start operation timed out").  This version of the recipe does
# not use virtual/phosphor-led-manager-config-native, so install the board
# configuration directly.  This runs after the recipe's own do_install:append,
# which removes JSON files that do not belong to an enabled interface namespace.
SRC_URI:append:ceb-gnrd = " file://led.json"

do_install:append:ceb-gnrd() {
    install -d ${D}${datadir}/phosphor-led-manager
    install -m 0644 ${UNPACKDIR}/led.json \
        ${D}${datadir}/phosphor-led-manager/led-group-config.json
}
