#!/bin/sh
# Run the ceb-gnrd BMC image in QEMU (ast2600-evb) with the parts of the board
# that QEMU can emulate attached at their real addresses, and open the control
# panel (host-sim.py --gui: a window when there is a display, otherwise the web
# panel on http://localhost:8800):
#
#   flash   BMC flash (the built image) on FMC, a 64 MiB BIOS flash on SPI1
#   network MAC2 = eth0, the RJ45 port (192.168.185.200, port forwards below)
#           MAC3 = eth1, NC-SI (QEMU's user network answers NC-SI, DHCP 10.0.2.x)
#   I2C7    (Linux i2c-6)  0x48-0x4b  4 temperature sensors (tmp105, LM75 compatible)
#   I2C8    (Linux i2c-7)  0x58-0x5a  PSU slots
#   I2C11   (Linux i2c-10) 0x50-0x53  FRU EEPROM, 1 KiB like the FM24C08; all four
#                                     256-byte blocks are kept in files
#   I2C1-6  (Linux i2c-0..5) 0x50     one 256-byte EEPROM per PCIe slot bus
#   QMP     control socket used by the panel (host power, buttons, sensors)
#
# With the ceb-gnrd QEMU (built with OpenBMC, or by build-qemu.sh) also:
#   host    the host power sequence (power button, reset, PWRGD, BIOS boot OK,
#           POST codes on port 80h, the CPU on PECI) runs inside QEMU
#           (bmc-host-sim, state changes in ~/qemu-ceb-gnrd/host.log)
#   VUART   the host's COM port (SOL on ttyVUART0) on ~/qemu-ceb-gnrd/host-uart.sock,
#           which the panel plays as the host console
#   fans, CRPS PSUs (0x58/0x59, 0x5a empty and hot-pluggable), steady ADC inputs,
#   the NCT3015Y RTC (Linux i2c9 0x6f), CPU/DIMM temperatures over PECI
# With a stock QEMU, host-sim.py plays the host over QMP and UART3 (BMC ttyS2)
# stands in for the host serial port.
#
# Not emulated (test on the board): eSPI Virtual Wires and flash channel, KCS from
# a host, KVM video, USB virtual media.
#
# Usage:  run-qemu.sh
# Environment: DEPLOY (image directory), STATE (directory for the FRU EEPROM files
# and the sockets, default ~/qemu-ceb-gnrd), BIOS_FLASH (default ~/qemu-bios.bin),
# QEMU (default: the QEMU OpenBMC built for this image, found through its
# qemuboot.conf; else $STATE/qemu/bin/qemu-system-arm from build-qemu.sh; else
# qemu-system-arm from PATH), PANEL_PORT (default 8800), NO_PANEL=1 (no panel),
# PANEL_WEB=1 (the web panel even when there is a display).

SELF=$(readlink -f "$0")
TOOLS=$(dirname "$SELF")
DEPLOY=${DEPLOY:-$HOME/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd}
STATE=${STATE:-$HOME/qemu-ceb-gnrd}
BIOS_FLASH=${BIOS_FLASH:-$HOME/qemu-bios.bin}
PANEL_PORT=${PANEL_PORT:-8800}
IMAGE=$DEPLOY/obmc-phosphor-image-ceb-gnrd.static.mtd
QEMUBOOT=$DEPLOY/obmc-phosphor-image-ceb-gnrd.qemuboot.conf
QMP=$STATE/qmp.sock
UART_SOCK=$STATE/host-uart.sock

if [ -z "$QEMU" ] && [ -f "$QEMUBOOT" ]; then
    # the qemu-system-native that OpenBMC built (with the ceb-gnrd patches)
    bindir=$(sed -n 's/^staging_bindir_native *= *//p' "$QEMUBOOT" | head -n 1)
    [ -x "$bindir/qemu-system-arm" ] && QEMU=$bindir/qemu-system-arm
fi
if [ -z "$QEMU" ] && [ -x "$STATE/qemu/bin/qemu-system-arm" ]; then
    QEMU=$STATE/qemu/bin/qemu-system-arm
fi
QEMU=${QEMU:-qemu-system-arm}
echo "QEMU: $QEMU"

if [ ! -f "$IMAGE" ]; then
    echo "BMC image not found: $IMAGE (set DEPLOY)" >&2
    exit 1
fi
mkdir -p "$STATE" || exit 1
[ -f "$BIOS_FLASH" ] || truncate -s 64M "$BIOS_FLASH"
rm -f "$QMP"

DEVICES=$("$QEMU" -device help 2>/dev/null)
if echo "$DEVICES" | grep -q bmc-host-sim; then
    BOARD_QEMU=1
else
    BOARD_QEMU=
    echo "note: this QEMU has no ceb-gnrd models (fans read 0 RPM, no VUART, no PECI);" >&2
    echo "      build OpenBMC again or run build-qemu.sh to get them" >&2
fi

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
# with the PMBus linear format.  The board QEMU has a CRPS supply model (voltages,
# currents, power, temperatures, fan; hot plug and AC loss): two modules and an
# empty third slot.  Otherwise QEMU's adm1266 (linear format, voltages only); the
# isl69260 and adm1272 report the direct format, which the generic driver rejects.
if echo "$DEVICES" | grep -q crps-psu; then
    PSU="-device crps-psu,bus=aspeed.i2c.bus.7,address=0x58,id=psu0"
    PSU="$PSU -device crps-psu,bus=aspeed.i2c.bus.7,address=0x59,id=psu1"
    PSU="$PSU -device crps-psu,bus=aspeed.i2c.bus.7,address=0x5a,id=psu2,present=false"
else
    PSU_MODEL=isl69260
    echo "$DEVICES" | grep -q adm1266 && PSU_MODEL=adm1266
    PSU="-device $PSU_MODEL,bus=aspeed.i2c.bus.7,address=0x58,id=psu0"
    PSU="$PSU -device $PSU_MODEL,bus=aspeed.i2c.bus.7,address=0x59,id=psu1"
fi

# Board QEMU: the host inside QEMU, the RTC, and steady ADC inputs at the nominal
# rail voltages divided as in the Entity-Manager configuration (pad mV = rail /
# ScaleFactor).  D3V0_BAT0 (3.0 V, ScaleFactor 1) is above the 2.5 V reference,
# so it reads 2.5 V and trips its low threshold, as on the board with that
# configuration.  The host serial port is the VUART (SOL on ttyVUART0).
# Stock QEMU: no VUART, so UART3 (BMC ttyS2) stands in for it (README.md).
BOARD=""
if [ -n "$BOARD_QEMU" ]; then
    BOARD="-device bmc-host-sim,id=host,gpio=/machine/soc/gpio,peci=/machine/soc/peci,lpc=/machine/soc/lpc"
    BOARD="$BOARD -trace bmc_host_sim_state -D $STATE/host.log"
    BOARD="$BOARD -device nct3018y,bus=aspeed.i2c.bus.9,address=0x6f,id=rtc"
    ch=0
    for mv in 1091 455 1650 1800 900 1130 850 1000 1800 1130 1800 1650 1800 1200 1000 3000; do
        BOARD="$BOARD -global aspeed.adc.ch$ch-mv=$mv"
        ch=$((ch + 1))
    done
    UART3=null
    VUART="-chardev socket,id=vuart,path=$UART_SOCK,server=on,wait=off"
    echo "Host inside QEMU, state changes in $STATE/host.log"
else
    UART3="unix:$UART_SOCK,server=on,wait=off"
    VUART=""
fi
echo "Host serial port (SOL): $UART_SOCK"

# Control panel: waits for QEMU's QMP socket, stops when QEMU stops
if [ -z "$NO_PANEL" ]; then
    python3 "$TOOLS/host-sim.py" --gui ${PANEL_WEB:+--web} --port "$PANEL_PORT" \
        --qmp "$QMP" --uart "$UART_SOCK" > "$STATE/panel.log" 2>&1 &
    if [ -n "$DISPLAY$WAYLAND_DISPLAY" ] && [ -z "$PANEL_WEB" ]; then
        echo "Control panel: a window (log $STATE/panel.log)"
    else
        echo "Control panel: http://localhost:$PANEL_PORT (log $STATE/panel.log)"
    fi
fi

# Serial ports: the first is UART5 (BMC debug console, this terminal), then
# UART1, UART2, UART3.
# shellcheck disable=SC2086
exec "$QEMU" -M ast2600-evb -m 1G -nographic -monitor none \
  -qmp "unix:$QMP,server=on,wait=off" \
  $VUART \
  -serial stdio -serial null -serial null -serial "$UART3" \
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
  $PSU \
  $FRU \
  $PCIE \
  $BOARD
