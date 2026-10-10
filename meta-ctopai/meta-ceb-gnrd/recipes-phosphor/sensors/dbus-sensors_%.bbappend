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
    file://0005-fan-use-resolved-pwm-enable-path.patch \
    file://0006-psu-log-filtered-devices-at-debug-level.patch \
    file://0007-psu-log-cancelled-poll-timer-at-debug-level.patch \
    file://0008-fan-log-unmatched-inputs-at-debug-level.patch \
    file://0009-psu-log-unmatched-devices-at-debug-level.patch \
    file://0010-hwmon-temp-skip-peci-auxiliary-devices.patch \
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
