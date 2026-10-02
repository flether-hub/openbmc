FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://gpio_defs.json"

# The recipe installs gpio_defs.json into /etc/default/obmc/gpio but lists it in no
# sub-package, so it lands in the (otherwise empty) main package.  Nothing in the
# image needs that package, so the file was missing and the "buttons" daemon
# (obmc-phosphor-buttons-signals) crashed on an empty configuration
# ("parse error ... attempting to parse an empty input").  Install the file here
# (the recipe's own conditional install is not relied on) and ship it with the
# daemon package.
do_install:append() {
    install -D -m 0644 ${UNPACKDIR}/gpio_defs.json \
        ${D}${sysconfdir}/default/obmc/gpio/gpio_defs.json
}

FILES:${PN}-signals:append = " ${sysconfdir}/default/obmc/gpio/gpio_defs.json"
