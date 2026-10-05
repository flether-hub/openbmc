FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " \
    file://gpio_defs.json \
    file://ceb-gnrd-wait-buttons.sh \
    file://10-ceb-gnrd-wait-buttons.conf \
    "

# The recipe installs gpio_defs.json into /etc/default/obmc/gpio but lists it in no
# sub-package, so it lands in the (otherwise empty) main package.  Nothing in the
# image needs that package, so the file was missing and the "buttons" daemon
# (obmc-phosphor-buttons-signals) crashed on an empty configuration
# ("parse error ... attempting to parse an empty input").  Install the file here
# (the recipe's own conditional install is not relied on) and ship it with the
# daemon package.
#
# phosphor-button-handler registers the UID button only if the object already
# exists when it starts, and the buttons daemon takes its bus name before it has
# exported its objects: started together they race and the UID button does
# nothing.  A drop-in makes the handler wait for the UID object first.
do_install:append() {
    install -D -m 0644 ${UNPACKDIR}/gpio_defs.json \
        ${D}${sysconfdir}/default/obmc/gpio/gpio_defs.json
    install -D -m 0755 ${UNPACKDIR}/ceb-gnrd-wait-buttons.sh \
        ${D}${libexecdir}/ceb-gnrd-wait-buttons.sh
    install -D -m 0644 ${UNPACKDIR}/10-ceb-gnrd-wait-buttons.conf \
        ${D}${systemd_system_unitdir}/phosphor-button-handler.service.d/10-ceb-gnrd-wait-buttons.conf
}

FILES:${PN}-signals:append = " ${sysconfdir}/default/obmc/gpio/gpio_defs.json"
FILES:${PN}-handler:append = " \
    ${libexecdir}/ceb-gnrd-wait-buttons.sh \
    ${systemd_system_unitdir}/phosphor-button-handler.service.d \
    "
