# Keep the newest entries; the persistent rwfs is only 14 MiB.
ERR_INFO_CAP:ceb-gnrd = "64"
EXTRA_OEMESON:append:ceb-gnrd = " -Derror_cap=64"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-bound-event-entry-storage.patch"
