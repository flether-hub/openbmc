# Consume the board-specific ADC, fan and temperature definitions installed by
# Entity-Manager.  The Xeon 6 CPU and DIMM temperatures are not published by
# IntelCPUSensor (no XeonCPU configuration, so no per-core / per-DIMM sensor
# shows up in IPMI, Redfish or the web page): ceb-gnrd-temp-max reads the kernel
# PECI hwmon devices and publishes only CPU_MAX_TEMP and DIMM_MAX_TEMP.
PACKAGECONFIG:append:ceb-gnrd = " \
    adcsensor \
    exitairtempsensor \
    fansensor \
    hwmontempsensor \
    intrusionsensor \
    psusensor \
    "

PACKAGECONFIG:remove:ceb-gnrd = "intelcpusensor"
