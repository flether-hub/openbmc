FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable eSPI and PECI kernel options for Intel host integration.
SRC_URI:append = " file://espi-peci.cfg"
