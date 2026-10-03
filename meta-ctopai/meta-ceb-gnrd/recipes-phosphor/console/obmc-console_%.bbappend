FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Port specific configuration for the host serial console (OBMC_CONSOLE_HOST_TTY =
# ttyVUART0): the upstream one without console-id, so the socket keeps the default
# name that bmcweb and IPMI SOL connect to.
SRC_URI:append:ceb-gnrd = " file://server.ttyVUART0.conf"
