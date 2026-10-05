# CEB-GNRD in QEMU

`run-qemu.sh` starts the built image on QEMU's `ast2600-evb` machine with the
board parts that QEMU emulates at their real bus addresses; `host-sim.py` plays
the motherboard behind the BMC's GPIOs through QEMU's QMP socket.  Nothing in
the BMC firmware is changed for this.

| Interface | Simulated by |
|---|---|
| Power button / reset outputs, PWRGD, BIOS boot OK | `host-sim.py` (power on, OS shutdown, forced off, reset, POST time) |
| Front panel power button input, UID button | `host-sim.py` commands `power`, `power-hold`, `uid` |
| BIOS flash (SPI1, 64 MiB) and its select GPIO | `run-qemu.sh` (`~/qemu-bios.bin`); `host-sim.py` warns when the BMC takes the flash while the host is on |
| NC-SI port (MAC3, eth1) | `run-qemu.sh` (QEMU answers NC-SI, DHCP 10.0.2.x) |
| 4 temperature sensors (I2C7 0x48-0x4b) | `run-qemu.sh` (tmp105), `host-sim.py` command `temp` |
| FRU EEPROM (I2C11 0x50-0x53, 1 KiB) | `run-qemu.sh`, the four blocks kept in `~/qemu-ceb-gnrd/fru0.bin` .. `fru3.bin` |
| PSU slots (I2C8 0x58-0x5a) | `run-qemu.sh`, QEMU's adm1266 PMBus model at 0x58 and 0x59 (PMBus linear format, so the generic `pmbus` driver binds; voltage readings only, not a CRPS supply), 0x5a empty.  isl69260 and adm1272 use the direct format, which the generic driver rejects; without an adm1266 model the script falls back to isl69260 |
| PCIe slot I2C buses (I2C1-6) | `run-qemu.sh`, a 256-byte EEPROM at 0x50 on each |
| Fan PWM/TACH (SYS_FAN0-5) | the QEMU built by `build-qemu.sh`: fan speed = 12000 RPM x PWM duty, `host-sim.py` command `fan` |

## Patched QEMU

Stock QEMU leaves the AST2600 PWM/TACH controller out, so the fans read 0 RPM.
`build-qemu.sh` builds upstream QEMU (tag `v11.1.2`) with the patches in
`patches/` on the x86 Linux build server and installs it in
`~/qemu-ceb-gnrd/qemu`, where `run-qemu.sh` picks it up (`QEMU=` overrides):

```
sudo apt install git build-essential ninja-build pkg-config python3-venv \
     libglib2.0-dev libpixman-1-dev libslirp-dev flex bison
~/openbmc/meta-ctopai/meta-ceb-gnrd/tools/qemu/build-qemu.sh
```

| Patch | Effect |
|---|---|
| 0001 | SCU reports the AHB clock (HCLK) the way the Linux clock driver computes it |
| 0002 | PWM/TACH controller at 0x1e610000: tach channel N reads the fan on PWM channel N, `fan-max-rpm` (12000) x duty, or a fixed `fanN-rpm` |

The fan speeds can also be set over QMP without `host-sim.py`:
`qom-set /machine/soc/pwm fan2-rpm 0` (stalled fan), `fan2-rpm -1` (follow the
PWM again), `fan-max-rpm 15000`.  On the BMC, `cat /sys/class/hwmon/hwmon*/fan1_input`
(the `aspeed_tach` hwmon device) shows the speed.

FRU: `ipmitool fru print/write 0` read and write the FRU EEPROM through
fru-device (ipmid's dynamic-sensors option), which only knows EEPROMs that
already hold a valid FRU.  The `ceb-gnrd-fru` package therefore writes a default
placeholder FRU into a blank EEPROM at boot (chassis type 0x17, which makes it FRU
ID 0), so a fresh `~/qemu-ceb-gnrd/fru0.bin` can be written with
`ipmitool fru write 0 fru.bin` straight away, and it asks fru-device to rescan
3 s after every FRU write so `ipmitool fru print 0` shows the new data.  To
re-seed the default image, delete `~/qemu-ceb-gnrd/fru*.bin` and restart QEMU.

## SOL without the VUART

QEMU has no VUART, so the host serial console is played by UART3 (BMC ttyS2),
which `run-qemu.sh` connects to `~/qemu-ceb-gnrd/host-uart.sock`.  Only the
running BMC is changed, a BMC reboot restores the normal SOL on ttyVUART0.  On
the BMC:

```
systemctl stop obmc-console@ttyVUART0.service
obmc-console-server --config /etc/obmc-console/server.ttyVUART0.conf ttyS2 &
```

On Ubuntu, the "host" end (type here, read the web SOL page or
`ipmitool -I lanplus -H 127.0.0.1 -p 2623 -U root -P 0penBmc sol activate`):

```
socat -,raw,echo=0 UNIX-CONNECT:$HOME/qemu-ceb-gnrd/host-uart.sock
```

or a real x86 guest whose COM1 is that socket:
`qemu-system-x86_64 ... -serial unix:$HOME/qemu-ceb-gnrd/host-uart.sock`.

Not emulated, test on the board: eSPI (VUART/SOL, KCS, POST codes, Virtual Wire),
PECI (CPU/DIMM temperatures), KVM video, USB virtual media, the NCT3015Y RTC.

## Use

On the build machine (Ubuntu), first terminal:

```
~/openbmc/meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh
```

Second terminal, once QEMU runs (Python 3, standard library only):

```
python3 ~/openbmc/meta-ctopai/meta-ceb-gnrd/tools/qemu/host-sim.py
```

The simulated host starts powered off.  Power it on from the web page, Redfish
or `ipmitool chassis power on`, and watch both terminals.  Commands typed into
`host-sim.py`:

| Command | Effect |
|---|---|
| `status` | host state, GPIO levels, temperatures |
| `power` / `power-hold` | front panel power button 0.5 s / 5 s |
| `uid` | UID button (toggles the identify LED) |
| `hang on` / `hang off` | BIOS never signals POST complete (alert LED boot timeout, 600 s) |
| `powerfail` | power good drops suddenly |
| `temp <inlet\|outlet\|pcie\|m2\|all> <C>` | sensor temperature |
| `fan <0-5\|all> <rpm\|auto>` / `fan max <rpm>` | fixed fan speed or back to following the PWM / speed at 100% PWM |
| `post <s>` / `shutdown <s>` | POST time (default 20 s) / OS shutdown time (default 10 s) |
| `quit` | stop the simulator (QEMU keeps running) |

Environment for `run-qemu.sh`: `DEPLOY` (image directory, default
`~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd`), `STATE` (FRU EEPROM and
QMP socket, default `~/qemu-ceb-gnrd`), `BIOS_FLASH` (default `~/qemu-bios.bin`),
`QEMU` (default `~/qemu-ceb-gnrd/qemu/bin/qemu-system-arm` when built, else the
one in `PATH`).
