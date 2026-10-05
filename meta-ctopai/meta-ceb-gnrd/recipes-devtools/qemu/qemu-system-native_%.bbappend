# The QEMU that OpenBMC builds for runqemu (qemu-helper-native, see meta-aspeed's
# aspeed.inc) gets the ceb-gnrd board models: fan tachometers, the simulated host
# behind the GPIOs, steady ADC inputs, GPIO reset tolerance, CRPS PSUs, a CPU on
# PECI, the NCT3015Y RTC, the VUART and the port 80h snoop.  The patches are the
# same ones tools/qemu/build-qemu.sh applies to a standalone QEMU; they are made
# for the QEMU version of this OE-core (11.0.2) and need a refresh when it moves.
# run-qemu.sh finds the binary through the image's qemuboot.conf.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../tools/qemu/patches:"

SRC_URI += " \
    file://0001-aspeed-scu-report-the-AST2600-AHB-clock-HCLK.patch \
    file://0002-aspeed-pwm-model-the-fan-tachometers-and-wire-the-co.patch \
    file://0003-hw-misc-add-bmc-host-sim-a-simulated-host-behind-the.patch \
    file://0004-aspeed-adc-settable-input-voltages.patch \
    file://0005-aspeed-gpio-keep-pin-levels-and-reset-tolerant-outpu.patch \
    file://0006-hw-sensor-add-crps-psu-a-generic-CRPS-PMBus-power-su.patch \
    file://0007-aspeed-peci-answer-as-an-Intel-CPU-at-address-0x30.patch \
    file://0008-bmc-host-sim-the-CPU-answers-PECI-only-while-the-hos.patch \
    file://0009-hw-rtc-add-the-Nuvoton-NCT3018Y-NCT3015Y-I2C-RTC.patch \
    file://0010-aspeed-AST2600-VUART-and-LPC-snoop-port-80h-POST-cod.patch \
    file://0011-bmc-host-sim-POST-codes-on-port-80h-during-POST.patch \
    file://0012-aspeed-read-only-fan-speed-PWM-duty-and-POST-code-pr.patch \
    file://0013-aspeed-gpio-a-pin-switched-to-output-drives-the-last.patch \
    file://0014-aspeed-AST2600-video-engine-with-a-still-picture-for.patch \
    file://0015-aspeed-gpio-read-only-gpio-dir-N-properties.patch \
    file://0016-aspeed-video-signal-a-mode-detection-when-the-input-.patch \
    "
