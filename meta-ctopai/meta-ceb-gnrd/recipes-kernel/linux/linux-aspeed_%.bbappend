# Add eSPI and PECI support to AST2600 based CEB-GNRD platform
KERNEL_CONFIG_FRAGMENTS:append = " ${THISDIR}/files/espi-peci.cfg"

# Include device tree patches for Intel platform integration
SRC_URI:append = " file://0001-aspeed-ast2600-enable-espi-peci-for-intel.patch"
