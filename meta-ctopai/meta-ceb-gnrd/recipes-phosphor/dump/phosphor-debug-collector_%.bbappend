# Persistent rwfs is 14 MiB; reserve space for settings and event logs.
EXTRA_OEMESON:append:ceb-gnrd = " -DBMC_DUMP_MAX_SIZE=200 -DBMC_DUMP_TOTAL_SIZE=512"

FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-collect-chassis-interface-and-ram-sol.patch"
