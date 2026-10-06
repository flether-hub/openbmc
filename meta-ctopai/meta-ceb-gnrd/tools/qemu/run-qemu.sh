#!/bin/sh
# Run the ceb-gnrd BMC image in QEMU (ast2600-evb) with the parts of the board
# that QEMU can emulate attached at their real addresses, and open the control
# panel (browser panel on http://localhost:8800):
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
# With the ceb-gnrd QEMU built by BitBake also:
#   host    the host power sequence (power button, reset, PWRGD, BIOS boot OK,
#           POST codes on port 80h, the CPU on PECI) runs inside QEMU
#           (bmc-host-sim, state changes in ~/qemu-ceb-gnrd/host.log)
#   VUART   the host's COM1 over eSPI/QMP (legacy models use host-uart.sock),
#           which the panel plays as the host console
#   fans, CRPS PSUs (0x58/0x59, 0x5a empty and hot-pluggable), steady ADC inputs,
#   the NCT3015Y RTC (Linux i2c9 0x6f), CPU/DIMM temperatures over PECI
# With a stock QEMU, host-sim.py plays the host over QMP and UART3 (BMC ttyS2)
# stands in for the host serial port.
#
# Software-test models: eSPI Peripheral/VW readiness and reset, host KCS/COM1,
# VGA still frames, USB vHub HID and read-only virtual media, CHASI# latch.
# Not emulated: eSPI OOB/flash, electrical timing or an executing x86 host OS.
#
# Usage:  run-qemu.sh
# Environment: DEPLOY (image directory), STATE (directory for the FRU EEPROM files
# and the sockets, default ~/qemu-ceb-gnrd), BIOS_FLASH (default ~/qemu-bios.bin),
# QEMU is always selected from the image qemuboot.conf (BitBake native build).
# PANEL_PORT (default 8800), NO_PANEL=1 (headless host I/O),
# NETWORK_CAPTURE=1 (Ethernet packets in $STATE/management.pcap),
# PECI_CPU (gnrd by default, spr for the previous Sapphire Rapids model).

SELF=$(readlink -f "$0")
TOOLS=$(dirname "$SELF")
DEPLOY=${DEPLOY:-$HOME/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd}
STATE=${STATE:-$HOME/qemu-ceb-gnrd}
BIOS_FLASH=${BIOS_FLASH:-$HOME/qemu-bios.bin}
PANEL_PORT=${PANEL_PORT:-8800}
case "${PECI_CPU:-gnrd}" in
    gnrd) PECI_CPUID=0x000a06e0 ;;
    spr) PECI_CPUID=0x000806f8 ;;
    *) echo "PECI_CPU must be gnrd or spr" >&2; exit 1 ;;
esac
IMAGE=$DEPLOY/obmc-phosphor-image-ceb-gnrd.static.mtd
QEMUBOOT=$DEPLOY/obmc-phosphor-image-ceb-gnrd.qemuboot.conf
QMP=$STATE/qmp.sock
UART_SOCK=$STATE/host-uart.sock

# Always use the emulator built with this image, even if QEMU is exported.
if [ ! -f "$QEMUBOOT" ]; then
    echo "QEMU configuration not found: $QEMUBOOT" >&2
    echo "Build the image first: bitbake obmc-phosphor-image" >&2
    exit 1
fi
bindir=$(sed -n 's/^staging_bindir_native *= *//p' "$QEMUBOOT" | head -n 1)
# Yocto stores native paths relative to DEPLOY_DIR_IMAGE for relocatability.
# Resolve from the configuration directory, not the caller's working directory.
case "$bindir" in
    ""|/*) ;;
    *) bindir=$(cd "$(dirname "$QEMUBOOT")" && readlink -m "$bindir") || exit 1 ;;
esac
if [ -z "$bindir" ] || [ ! -x "$bindir/qemu-system-arm" ]; then
    echo "BitBake QEMU not found: ${bindir:-<missing staging_bindir_native>}/qemu-system-arm" >&2
    echo "Rebuild the image: bitbake obmc-phosphor-image" >&2
    exit 1
fi
QEMU=$bindir/qemu-system-arm
echo "QEMU: $QEMU"

if [ ! -f "$IMAGE" ]; then
    echo "BMC image not found: $IMAGE (set DEPLOY)" >&2
    exit 1
fi
mkdir -p "$STATE" || exit 1
[ -f "$BIOS_FLASH" ] || truncate -s 64M "$BIOS_FLASH"
rm -f "$QMP"

DEVICES=$("$QEMU" -device help 2>/dev/null)
HOST_PROPS=$("$QEMU" -device bmc-host-sim,help 2>/dev/null)
if echo "$HOST_PROPS" | grep -q 'espi'; then
    HOST_IO_QEMU=1
else
    HOST_IO_QEMU=
fi
if echo "$DEVICES" | grep -q bmc-host-sim; then
    BOARD_QEMU=1
    echo "PECI CPU profile: ${PECI_CPU:-gnrd} (requires patch 0019 for GNR-D semantics)"
else
    BOARD_QEMU=
    echo "note: this QEMU has no ceb-gnrd models (fans read 0 RPM, no VUART, no PECI);" >&2
    echo "      rebuild OpenBMC to get them" >&2
fi

# FM24C08: four 256-byte, one-byte-addressed blocks at 0x50..0x53.
# Raw block backends report sector-aligned lengths, so retain the existing
# 512-byte files but expose only the first 256 bytes through backing-size.
# Existing EEPROM files are preserved across BMC and simulator restarts.
FRU=""
for blk in 0 1 2 3; do
    f=$STATE/fru$blk.bin
    if [ "$(wc -c < "$f" 2>/dev/null)" != 512 ]; then
        head -c 512 /dev/zero | LC_ALL=C tr '\000' '\377' > "$f"
    fi
    FRU="$FRU -drive file=$f,format=raw,if=none,id=fru$blk"
    FRU="$FRU -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x5$blk,rom-size=256,backing-size=512,address-size=1,drive=fru$blk"
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
    if [ -n "$HOST_IO_QEMU" ]; then
        BOARD="$BOARD,espi=/machine/soc/espi"
    else
        echo "note: QEMU lacks patch 0018; rebuild for eSPI/USB/CHASI# testing" >&2
    fi
    BOARD="$BOARD -trace bmc_host_sim_state -D $STATE/host-log.pipe"
    BOARD="$BOARD -device nct3018y,bus=aspeed.i2c.bus.9,address=0x6f,id=rtc"
    BOARD="$BOARD -global driver=aspeed.peci,property=cpuid,value=$PECI_CPUID"
    ch=0
    for mv in 1091 455 1650 1800 900 1130 850 1000 1800 1130 1800 1650 1800 1200 1000 3000; do
        # long form: the short one splits "aspeed.adc.chN-mv" at the first dot
        BOARD="$BOARD -global driver=aspeed.adc,property=ch$ch-mv,value=$mv"
        ch=$((ch + 1))
    done
    UART3=null
    if [ -n "$HOST_IO_QEMU" ]; then
        VUART="" # Peripheral I/O accesses go through QMP, no serial bypass.
    else
        VUART="-chardev socket,id=vuart,path=$UART_SOCK,server=on,wait=off"
    fi
    echo "Host inside QEMU, state changes in $STATE/host.log"
else
    UART3="unix:$UART_SOCK,server=on,wait=off"
    VUART=""
fi
if [ -n "$HOST_IO_QEMU" ]; then
    echo "Host serial port (SOL): eSPI Peripheral / COM1 via QMP"
else
    echo "Host serial port (SOL): $UART_SOCK"
fi

# Control panel: waits for QEMU's QMP socket, stops when QEMU stops
# FIFO readers own and rotate the output files; QEMU never holds a renamed log.
LOG_PIDS=
for name in host panel qemu; do
    fifo="$STATE/$name-log.pipe"
    rm -f "$fifo"
    mkfifo "$fifo" || exit 1
    python3 "$TOOLS/log-sink.py" "$STATE/$name.log" < "$fifo" &
    LOG_PIDS="$LOG_PIDS $!"
done
PANEL_PID=
cleanup_panel() {
    if [ -n "$PANEL_PID" ]; then
        kill "$PANEL_PID" 2>/dev/null || :
        wait "$PANEL_PID" 2>/dev/null || :
    fi
    # Writers have stopped; give sinks a short interval to drain queued bytes
    # before terminating any reader
    # that was never connected (for example no host trace model).
    sleep 0.2
    for pid in $LOG_PIDS; do
        kill "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
    done
    rm -f "$STATE/host-log.pipe" "$STATE/panel-log.pipe" "$STATE/qemu-log.pipe"
}
trap cleanup_panel EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [ -z "$NO_PANEL" ]; then
    python3 "$TOOLS/host-sim.py" --web --port "$PANEL_PORT" \
        --state-dir "$STATE" \
        --qmp "$QMP" --uart "$UART_SOCK" > "$STATE/panel-log.pipe" 2>&1 &
    echo "Control panel: http://localhost:$PANEL_PORT (log $STATE/panel.log)"
else
    # Keep host USB, COM1 and VGA behaviour running without a visible panel.
    python3 "$TOOLS/host-sim.py" --headless --qmp "$QMP" --uart "$UART_SOCK" \
        --state-dir "$STATE" > "$STATE/panel-log.pipe" 2>&1 &
fi
PANEL_PID=$!
echo "QEMU component diagnostics: $STATE/qemu.log (BMC UART remains on this terminal)"

# Optional capture of the existing management NIC; no generated ping or ARP.
# It remains active across a guest reboot, so old/new destination MACs and
# delivery before/after the guest's first transmit can be compared.
CAPTURE_ARGS=
if [ "${NETWORK_CAPTURE:-0}" = 1 ]; then
    CAPTURE_ARGS="-object filter-dump,id=ceb-net-capture,netdev=ceb-management,file=$STATE/management.pcap"
    echo "Management Ethernet capture: $STATE/management.pcap"
fi

# Serial ports: the first is UART5 (BMC debug console, this terminal), then
# UART1, UART2, UART3.
# shellcheck disable=SC2086
"$QEMU" -M ast2600-evb -m 1G -nographic -monitor none \
  -qmp "unix:$QMP,server=on,wait=off" \
  $VUART \
  -serial stdio -serial null -serial null -serial "$UART3" \
  -drive file="$IMAGE",format=raw,if=mtd,index=0 \
  -drive file="$BIOS_FLASH",format=raw,if=mtd,index=1 \
  -nic user \
  -nic user,id=ceb-management,net=192.168.185.0/24,host=192.168.185.1,tftp=/srv/tftp,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623 \
  -nic user \
  -nic user,restrict=on \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x48,id=temp-inlet \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x49,id=temp-outlet \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x4a,id=temp-pcie \
  -device tmp105,bus=aspeed.i2c.bus.6,address=0x4b,id=temp-m2 \
  $PSU \
  $FRU \
  $PCIE \
  $BOARD $CAPTURE_ARGS 2> "$STATE/qemu-log.pipe"
QEMU_STATUS=$?
exit "$QEMU_STATUS"
