FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Port specific configuration for the physical host UART (OBMC_CONSOLE_HOST_TTY
# = ttyS2).  Without it the generic VUART style obmc-console.conf is used.
SRC_URI:append:ceb-gnrd = " file://server.ttyS2.conf"
