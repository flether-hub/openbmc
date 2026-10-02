FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://gpio_defs.json"

# The recipe installs gpio_defs.json into /etc/default/obmc/gpio but lists it in no
# sub-package, so it lands in the (otherwise empty) main package.  Nothing in the
# image needs that package, so the file was missing and the "buttons" daemon
# (obmc-phosphor-buttons-signals) crashed on an empty configuration
# ("parse error ... attempting to parse an empty input").  Ship it with the daemon.
FILES:${PN}-signals:append = " ${sysconfdir}/default/obmc/gpio/gpio_defs.json"
