FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"

# Fan tach sensors are powered with host DC on this board. Confirmed Chassis
# Off suppresses missing readings; pending shutdown/reset retains cooling.
SRC_URI:append:ceb-gnrd = " \
    file://0001-ceb-gnrd-ignore-fan-tach-failures-while-host-off.patch \
    file://0002-ceb-gnrd-deduplicate-failsafe-state-logs.patch \
    file://0003-ceb-gnrd-quiet-fan-logs-during-host-transitions.patch \
    file://0004-ceb-gnrd-use-dc-power-for-thermal-gating.patch \
    "
