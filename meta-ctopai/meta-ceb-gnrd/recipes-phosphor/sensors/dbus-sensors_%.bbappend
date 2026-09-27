# Keep the Xeon 6 sensor applications enabled and consume the board-specific
# ADC, fan and temperature definitions installed by Entity-Manager.
PACKAGECONFIG:append:ceb-gnrd = " \
    adcsensor \
    exitairtempsensor \
    fansensor \
    hwmontempsensor \
    intelcpusensor \
    intrusionsensor \
    psusensor \
    "
