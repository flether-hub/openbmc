FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Physical UART3 owns the default endpoint used by Web and IPMI SOL. VUART1
# has a distinct console-id so both servers can run without a socket collision.
SRC_URI:append:ceb-gnrd = " file://server.ttyS2.conf file://server.ttyVUART0.conf"
# Keep the existing SSH console attached to the default physical endpoint.
SYSTEMD_SERVICE:${PN}:remove:ceb-gnrd = "obmc-console-ssh@ttyVUART0.service"
