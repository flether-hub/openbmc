#!/bin/sh
# Run the ceb-gnrd BMC image in QEMU (ast2600-evb) with the parts of the board
# that QEMU can emulate attached at their real addresses:
#
#   flash   BMC flash (the built image) on FMC, a 64 MiB BIOS flash on SPI1
#   network MAC2 = eth0, the RJ45 port (192.168.185.200, port forwards below)
#           MAC3 = eth1, NC-SI (QEMU's user network answers NC-SI, DHCP 10.0.2.x)
#   I2C7    (Linux i2c-6)  0x48-0x4b  4 temperature sensors (tmp105, LM75 compatible)
#   I2C8    (Linux i2c-7)  0x58, 0x59 2 PMBus "PSUs" (QEMU's adm1266, linear PMBus
#                                     format so the generic pmbus driver binds: presence
#                                     and driver tests, voltage readings only); 0x5a empty
#   I2C11   (Linux i2c-10) 0x50-0x53  FRU EEPROM, 1 KiB like the FM24C08; all four
#                                     256-byte blocks are kept in files
#   I2C1-6  (Linux i2c-0..5) 0x50     one 256-byte EEPROM per PCIe slot bus
#   PWM/TACH fan speeds follow the PWM duty (needs the QEMU from build-qemu.sh)
#   patched QEMU only: CRPS PSUs at 0x58/0x59 (0x5a empty, hot-pluggable), the
#   NCT3015Y RTC on Linux i2c9 0x6f, steady ADC voltages, PECI CPU/DIMM temps
#   QMP     control socket used by host-sim.py (host power, buttons, temperatures)
#   host    with the QEMU from build-qemu.sh the host power sequence (power button,
#           reset, PWRGD, BIOS boot OK) runs inside QEMU (bmc-host-sim device,
#           log in ~/qemu-ceb-gnrd/host.log); host-sim.py is then only a console
#
#   UART3   (BMC ttyS2) on ~/qemu-ceb-gnrd/host-uart.sock: the host serial port
#           for SOL tests (QEMU has no VUART; see tools/qemu/README.md)
#
# Not emulated (test on the board): eSPI/VUART/KCS/POST codes, PECI, KVM video,
# USB virtual media; with a stock QEMU also fans, RTC, PECI and steady ADC values.
#
# Usage:  run-qemu.sh                      (then, in a second terminal: host-sim.py)
# Environment: DEPLOY (image directory), STATE (directory for the FRU EEPROM files
# and the QMP socket, default ~/qemu-ceb-gnrd), BIOS_FLASH (default ~/qemu-bios.bin),
# QEMU (default: $STATE/qemu/bin/qemu-system-arm from build-qemu.sh when it exists,
# otherwise qemu-system-arm from PATH).

DEPLOY=${DEPLOY:-$HOME/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd}
STATE=${STATE:-$HOME/qemu-ceb-gnrd}
BIOS_FLASH=${BIOS_FLASH:-$HOME/qemu-bios.bin}
IMAGE=$DEPLOY/obmc-phosphor-image-ceb-gnrd.static.mtd
if [ -z "$QEMU" ]; then
    if [ -x "$STATE/qemu/bin/qemu-system-arm" ]; then
        QEMU=$STATE/qemu/bin/qemu-system-arm
    else
        QEMU=qemu-system-arm
        echo "note: stock QEMU, fans read 0 RPM (build-qemu.sh builds the patched one)" >&2
    fi
fi
QMP=$STATE/qmp.sock

if [ ! -f "$IMAGE" ]; then
    echo "BMC image not found: $IMAGE (set DEPLOY)" >&2
    exit 1
fi
mkdir -p "$STATE" || exit 1
[ -f "$BIOS_FLASH" ] || truncate -s 64M "$BIOS_FLASH"
rm -f "$QMP"

# FRU EEPROM: the FM24C08 answers at 0x50-0x53, 256 bytes each, 1-byte offsets.
# QEMU's block layer counts a raw file in 512-byte sectors and at24c-eeprom wants
# file size == rom-size, so each block has a 512-byte file (erased = 0xff) with
# 1-byte addressing; the guest only uses the first 256 bytes.  LC_ALL=C: in a
# UTF-8 locale tr writes \377 as two bytes.  A file of another size is recreated.
FRU=""
for blk in 0 1 2 3; do
    f=$STATE/fru$blk.bin
    if [ "$(wc -c < "$f" 2>/dev/null)" != 512 ]; then
        head -c 512 /dev/zero | LC_ALL=C tr '\000' '\377' > "$f"
    fi
    FRU="$FRU -drive file=$f,format=raw,if=none,id=fru$blk"
    FRU="$FRU -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x5$blk,rom-size=512,address-size=1,drive=fru$blk"
done

# PCIe slot buses: an EEPROM at 0x50 on Linux i2c-0 .. i2c-5
PCIE=""
for bus in 0 1 2 3 4 5; do
    PCIE="$PCIE -device at24c-eeprom,bus=aspeed.i2c.bus.$bus,address=0x50,rom-size=256"
done

# PSU slots: the generic pmbus driver (what ceb-gnrd-psu-detect binds) only works
# with the PMBus linear format.  QEMU's adm1266 reports it (VOUT_MODE 0); the
# isl69260 and adm1272 report the direct format, which the generic driver rejects.
# The patched QEMU has a CRPS supply model (input/output voltage, current, power,
# temperatures, fan; hot plug and AC loss over QMP): two modules, slot 3 empty.
DEVICES=$("$QEMU" -device help 2>/dev/null)
PSU2=""
if echo "$DEVICES" | grep -q crps-psu; then
    PSU_MODEL=crps-psu
    PSU2="-device crps-psu,bus=aspeed.i2c.bus.7,address=0x5a,id=psu2,present=false"
elif echo "$DEVICES" | grep -q adm1266; then
    PSU_MODEL=adm1266
else
    PSU_MODEL=isl69260
    echo "warning: this QEMU has no adm1266 model, the PSU slots use $PSU_MODEL" >&2
fi

# Host power sequence inside QEMU (patched QEMU); otherwise host-sim.py plays it
HOST=""
if echo "$DEVICES" | grep -q bmc-host-sim; then
    HOST="-device bmc-host-sim,id=host,gpio=/machine/soc/gpio,peci=/machine/soc/peci"
    HOST="$HOST -trace bmc_host_sim_state -D $STATE/host.log"
    echo "Simulated host inside QEMU, state changes in $STATE/host.log"
fi

# Patched QEMU: the NCT3015Y RTC (Linux i2c9 0x6f) and steady ADC inputs at the
# nominal rail voltages divided as in the Entity-Manager configuration
# (pad mV = rail / ScaleFactor).  D3V0_BAT0 (3.0 V, ScaleFactor 1) is above the
# 2.5 V reference, so it reads 2.5 V and trips its low threshold, as it would on
# the board with that configuration.
EXTRA=""
if echo "$DEVICES" | grep -q nct3018y; then
    EXTRA="-device nct3018y,bus=aspeed.i2c.bus.9,address=0x6f,id=rtc"
    ch=0
    for mv in 1091 455 1650 1800 900 1130 850 1000 1800 1130 1800 1650 1800 1200 1000 3000; do
        EXTRA="$EXTRA -global aspeed.adc.ch$ch-mv=$mv"
        ch=$((ch + 1))
    done
fi

echo "QMP socket for host-sim.py: $QMP"
echo "Host serial console (UART3, for SOL tests): $STATE/host-uart.sock"
# Serial ports: the first is UART5 (BMC debug console, this terminal), then
# UART1, UART2, UART3 ...  UART3 (BMC ttyS2) goes to a socket that plays the host's
# serial port for SOL tests (QEMU has no VUART); see tools/qemu/README.md.
# shellcheck disable=SC2086
exec "$QEMU" -M ast2600-evb -m 1G -nographic -monitor none \
  -qmp "unix:$QMP,server=on,wait=off" \
  -serial stdio -serial null -serial null \
  -serial "unix:$STATE/host-uart.sock,server=on,wait=off" \
  -drive file="$IMAGE",format=raw,if=mtd,index=0 \
  -drive file="$BIOS_FLASH",format=raw,if=mtd,index=1 \
  -nic user \
  -nic user,net=192.168.185.0/24,host=192.168.185.1,tftp=/srv/tftp,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623 \
  -nic user \
  -nic user,restrict=on \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x48,id=temp-inlet \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x49,id=temp-outlet \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x4a,id=temp-pcie \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x4b,id=temp-m2 \
  -device $PSU_MODEL,bus=aspeed.i2c.bus.7,address=0x58,id=psu0 \
  -device $PSU_MODEL,bus=aspeed.i2c.bus.7,address=0x59,id=psu1 \
  $PSU2 \
  $FRU \
  $PCIE \
  $HOST \
  $EXTRA
