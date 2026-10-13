FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

# Fan tach sensors are powered with the host on this board. A confirmed Host
# Off state must not report missing tach readings as fan-control failures.
SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-ignore-fan-tach-failures-while-host-off.patch \
    file://0002-ceb-gnrd-deduplicate-failsafe-state-logs.patch \
    file://0003-ceb-gnrd-quiet-fan-logs-during-host-transitions.patch \
    "
