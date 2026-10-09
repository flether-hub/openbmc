# Consume the board-specific ADC, fan and temperature definitions installed by
# Entity-Manager.  The Xeon 6 CPU and DIMM temperatures are not published by
# IntelCPUSensor (no XeonCPU configuration, so no per-core / per-DIMM sensor
# shows up in IPMI, Redfish or the web page): ceb-gnrd-temp-max reads the kernel
# PECI hwmon devices and publishes only CPU_MAX_TEMP and DIMM_MAX_TEMP.
FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " \
    file://0001-reuse-i2c-device-by-config-path-and-guard-psu-io.patch \
    file://0002-ceb-gnrd-megcrps800-psu.patch \
    file://0003-ceb-gnrd-gate-chassis-adc-and-delayed-alarms.patch \
    file://0004-ceb-gnrd-persistent-intrusion-enable.patch \
    "

PACKAGECONFIG:append:ceb-gnrd = " \
    adcsensor \
    exitairtempsensor \
    fansensor \
    hwmontempsensor \
    intrusionsensor \
    psusensor \
    "

PACKAGECONFIG:remove:ceb-gnrd = "intelcpusensor"
