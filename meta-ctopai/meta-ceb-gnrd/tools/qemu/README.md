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
| PSU slots (I2C8 0x58-0x5a) | `run-qemu.sh`, QEMU's adm1272 PMBus model at 0x58 and 0x59 (presence detection and PMBus driver; the readings are not those of a CRPS supply), 0x5a empty |

To load a FRU image into the EEPROM (the BMC reads it at boot), on the BMC:

```
cat fru.bin > /sys/bus/i2c/devices/10-0050/eeprom
```

then reboot the BMC.  `ipmitool fru write` does not write the EEPROM on
OpenBMC, it only updates the inventory.
| PCIe slot I2C buses (I2C1-6) | `run-qemu.sh`, a 256-byte EEPROM at 0x50 on each |

Not emulated, test on the board: eSPI (VUART/SOL, KCS, POST codes, Virtual Wire),
PECI (CPU/DIMM temperatures), KVM video, USB virtual media, fan PWM/TACH, the
NCT3015Y RTC.

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
| `post <s>` / `shutdown <s>` | POST time (default 20 s) / OS shutdown time (default 10 s) |
| `quit` | stop the simulator (QEMU keeps running) |

Environment for `run-qemu.sh`: `DEPLOY` (image directory, default
`~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd`), `STATE` (FRU EEPROM and
QMP socket, default `~/qemu-ceb-gnrd`), `BIOS_FLASH` (default `~/qemu-bios.bin`).
