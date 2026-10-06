# Keep the real NBD/USB path and disconnect the gadget before cleanup.
FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-stop-reaping-on-echild-and-serialize-gadget-cleanup.patch"
