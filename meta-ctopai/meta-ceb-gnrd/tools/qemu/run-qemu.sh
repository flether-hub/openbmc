#!/bin/sh
# Run the ceb-gnrd BMC image in QEMU (ast2600-evb) with the parts of the board
# that QEMU can emulate attached at their real addresses:
#
#   flash   BMC flash (the built image) on FMC, a 64 MiB BIOS flash on SPI1
#   network MAC2 = eth0, the RJ45 port (192.168.185.200, port forwards below)
#           MAC3 = eth1, NC-SI (QEMU's user network answers NC-SI, DHCP 10.0.2.x)
#   I2C7    (Linux i2c-6)  0x48-0x4b  4 temperature sensors (tmp105, LM75 compatible)
#   I2C11   (Linux i2c-10) 0x50-0x53  FRU EEPROM, 1 KiB like the FM24C08 (0x50 is kept
#                                     in a file, so FRU writes survive a restart)
#   I2C1-6  (Linux i2c-0..5) 0x50     one 256-byte EEPROM per PCIe slot bus
#   QMP     control socket used by host-sim.py (host power, buttons, temperatures)
#
# Not emulated (test on the board): eSPI/VUART/KCS/POST codes, PECI, KVM video,
# USB virtual media, fan PWM/TACH, the NCT3015Y RTC.
#
# Usage:  run-qemu.sh                      (then, in a second terminal: host-sim.py)
# Environment: DEPLOY (image directory), STATE (directory for the BIOS flash, FRU
# EEPROM and QMP socket, default ~/qemu-ceb-gnrd), BIOS_FLASH (default ~/qemu-bios.bin).

DEPLOY=${DEPLOY:-$HOME/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd}
STATE=${STATE:-$HOME/qemu-ceb-gnrd}
BIOS_FLASH=${BIOS_FLASH:-$HOME/qemu-bios.bin}
IMAGE=$DEPLOY/obmc-phosphor-image-ceb-gnrd.static.mtd
QMP=$STATE/qmp.sock

if [ ! -f "$IMAGE" ]; then
    echo "BMC image not found: $IMAGE (set DEPLOY)" >&2
    exit 1
fi
mkdir -p "$STATE" || exit 1
[ -f "$BIOS_FLASH" ] || truncate -s 64M "$BIOS_FLASH"
# FRU EEPROM block 0x50 (256 bytes, erased = 0xff)
# (LC_ALL=C: in a UTF-8 locale tr writes \377 as two bytes; QEMU needs exactly
# 256 bytes, so a file of another size, e.g. from that bug, is recreated)
if [ "$(wc -c < "$STATE/fru.bin" 2>/dev/null)" != 256 ]; then
    head -c 256 /dev/zero | LC_ALL=C tr '\000' '\377' > "$STATE/fru.bin"
fi
rm -f "$QMP"

# PCIe slot buses: an EEPROM at 0x50 on Linux i2c-0 .. i2c-5
PCIE=""
for bus in 0 1 2 3 4 5; do
    PCIE="$PCIE -device at24c-eeprom,bus=aspeed.i2c.bus.$bus,address=0x50,rom-size=256"
done

echo "QMP socket for host-sim.py: $QMP"
# shellcheck disable=SC2086
exec qemu-system-arm -M ast2600-evb -m 1G -nographic -monitor none \
  -qmp "unix:$QMP,server=on,wait=off" \
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
  -drive file="$STATE/fru.bin",format=raw,if=none,id=fru0 \
  -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x50,rom-size=256,drive=fru0 \
  -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x51,rom-size=256 \
  -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x52,rom-size=256 \
  -device at24c-eeprom,bus=aspeed.i2c.bus.10,address=0x53,rom-size=256 \
  $PCIE
