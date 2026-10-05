# CEB-GNRD in QEMU

`run-qemu.sh` (also linked at the top of the repository) starts the built image
on QEMU's `ast2600-evb` machine with the board parts at their real bus
addresses, and opens the control panel at <http://localhost:8800>.  Nothing in
the BMC firmware is changed for this.

## The board QEMU

Building OpenBMC builds QEMU too: meta-aspeed already builds `qemu-system-native`
for `runqemu`, and `recipes-devtools/qemu/qemu-system-native_%.bbappend` adds the
patches in `patches/` to it.  `run-qemu.sh` finds that binary through the image's
`qemuboot.conf`, so after

```
bitbake obmc-phosphor-image
./run-qemu.sh
```

everything below works.  `build-qemu.sh` builds the same QEMU (11.0.2, the
version of this OE-core) outside Yocto into `~/qemu-ceb-gnrd/qemu`, which
`run-qemu.sh` uses when there is no Yocto build; `QEMU=` overrides both.  With a
stock QEMU `run-qemu.sh` still runs, and `host-sim.py` plays the host over QMP.

| Interface | Simulated by |
|---|---|
| Power button / reset outputs, PWRGD, BIOS boot OK | `bmc-host-sim` in QEMU: power on, OS shutdown, forced off, reset, POST time, BIOS hang, power failure |
| Front panel power button, UID button | panel buttons |
| POST codes (port 80h, LPC snoop) | `bmc-host-sim` writes a POST code series during POST; the panel shows them and can write one |
| Host serial port, SOL on ttyVUART0 | QEMU VUART on `~/qemu-ceb-gnrd/host-uart.sock`; the panel is the host console (boot messages, a shell that echoes) |
| CPU and DIMM temperatures (PECI) | a CPU at PECI 0x30 while the host is on; panel sliders |
| Fans SYS_FAN0-5 (PWM/TACH) | speed = 12000 RPM x PWM duty; panel: fail a fan, fix it, slow it |
| PSU slots (I2C8 0x58-0x5a) | `crps-psu` at 0x58 and 0x59 (VIN, VOUT, IIN, IOUT, PIN, POUT, two temperatures, fan), 0x5a empty; panel: insert, pull, AC loss, load, overheat |
| ADC0-15 | steady nominal rail voltages from the Entity-Manager dividers; panel table |
| 4 temperature sensors (I2C7 0x48-0x4b) | tmp105; panel sliders |
| NCT3015Y RTC (I2C10 0x6f) | `nct3018y`, keeps its time across BMC reboots; panel: battery low |
| BMC reboot | GPIO reset tolerance: the power, reset and flash select outputs hold, `BMC_FAN_BMC_OVERRIDE_N` resets |
| BIOS flash (SPI1, 64 MiB) | `~/qemu-bios.bin`; the panel log warns when the BMC takes it while the host is on |
| NC-SI port (MAC3, eth1) | QEMU answers NC-SI, DHCP 10.0.2.x |
| FRU EEPROM (I2C11 0x50-0x53, 1 KiB) | the four blocks kept in `~/qemu-ceb-gnrd/fru0.bin` .. `fru3.bin` |
| PCIe slot I2C buses (I2C1-6) | a 256-byte EEPROM at 0x50 on each |

Not emulated, test on the board: eSPI Virtual Wires and the flash channel, KCS
from a host OS, KVM video, USB virtual media.

## Control panel

`run-qemu.sh` starts `host-sim.py --gui` (log in `~/qemu-ceb-gnrd/panel.log`),
which serves the panel on <http://localhost:8800> (`PANEL_PORT=`) and opens a
browser when there is a display.  It listens on localhost only; from another
machine use an SSH tunnel: `ssh -L 8800:localhost:8800 <build server>`.  It
stops with QEMU.  `NO_PANEL=1 ./run-qemu.sh` leaves it out, for instance to use
`host-sim.py` as a command line console instead.

The panel shows:

- the signals between the BMC and the host, each line lit at its level (orange:
  a low-active signal asserted) with the front panel buttons on the host side,
  and the PECI, port 80h, VUART, PWM/TACH and I2C links;
- host control: power button short and 5 s, UID, power failure, BIOS hang,
  POST and shutdown times;
- the POST code display and history;
- fans, PSUs, temperatures, ADC voltages and the RTC battery;
- the host serial console: what the BMC sends over SOL, and a line to type
  what the host sends;
- the event log.

The QEMU socket accepts one client, so while the panel plays the host console,
`socat` cannot connect to `host-uart.sock`; start with `NO_PANEL=1` to use
`socat -,raw,echo=0 UNIX-CONNECT:$HOME/qemu-ceb-gnrd/host-uart.sock` or a real
x86 guest (`qemu-system-x86_64 ... -serial unix:$HOME/qemu-ceb-gnrd/host-uart.sock`).

## Command line console

`python3 host-sim.py` (Python 3, standard library only) reads commands from
stdin; with the board QEMU it is a console for the host inside QEMU, with a
stock QEMU it plays the host.

| Command | Effect |
|---|---|
| `status` | host state, GPIO levels, temperatures |
| `power` / `power-hold` | front panel power button 0.5 s / 5 s |
| `uid` | UID button (toggles the identify LED) |
| `hang on` / `hang off` | BIOS never signals POST complete (alert LED boot timeout, 600 s) |
| `powerfail` | power good drops suddenly |
| `temp <inlet\|outlet\|pcie\|m2\|all> <C>` | sensor temperature |
| `fan <0-5\|all> <rpm\|auto>` / `fan max <rpm>` | fixed fan speed or back to following the PWM / speed at 100% PWM |
| `psu <0-2> in\|out` / `psu <n> ac on\|off` / `psu <n> load <W>` / `psu <n> temp <C>` | insert or pull a PSU, AC loss, output power, hotspot temperature |
| `cpu <C>` / `dimm <C>` | CPU package / DIMM temperature over PECI |
| `adc <0-15> <mV>` | ADC pad voltage (rail divided by the ScaleFactor) |
| `rtc battery ok\|low` | RTC battery; low makes the driver refuse the RTC time |
| `postcode <hex>` | the host writes a byte to port 80h |
| `post <s>` / `shutdown <s>` | POST time (default 20 s) / OS shutdown time (default 10 s) |
| `quit` | stop the console (QEMU keeps running) |

## QEMU patches

| Patch | Effect |
|---|---|
| 0001 | SCU reports the AHB clock (HCLK) the way the Linux clock driver computes it |
| 0002 | PWM/TACH controller at 0x1e610000: tach channel N reads the fan on PWM channel N, `fan-max-rpm` (12000) x duty, or a fixed `fanN-rpm` |
| 0003 | `bmc-host-sim`: the host power sequence on the BMC GPIOs |
| 0004 | ADC: `chN-mv` input voltage per pad, read back steadily; compensation mode reads half scale so the driver's offset is 0 |
| 0005 | GPIO: a BMC reset keeps the pin levels and the outputs marked reset tolerant (the kernel marks every line user space requests; `ceb-gnrd-fan-owner` clears it for `BMC_FAN_BMC_OVERRIDE_N`) |
| 0006 | `crps-psu`: PMBus linear supply for the generic `pmbus` driver |
| 0007 | PECI: the controller answers as a CPU at 0x30 (Ping, GetDIB, GetTemp, RdPkgConfig, RdEndPointConfig) for peci-cputemp and peci-dimmtemp |
| 0008 | `bmc-host-sim` takes the CPU off PECI while the host is off |
| 0009 | `nct3018y`: the NCT3015Y RTC |
| 0010 | VUART at 0x1e787000 on the chardev with id `vuart`; LPC snoop (HICR5/6, SNPWADR, SNPWDR) on GIC 144 |
| 0011 | `bmc-host-sim` writes POST codes to port 80h during POST (stops at 0x92 when the BIOS hangs) |
| 0012 | read-only `fanN-speed`, `pwmN-duty` and `post-code` for the panel |

Everything is reachable over QMP (`~/qemu-ceb-gnrd/qmp.sock`) as well:
`/machine/peripheral/host` (`state`, `press-power-button`, `press-uid-button`,
`power-fail`, `hang`, `pwrgd-ms`, `post-ms`, `shutdown-ms`), `/machine/soc/pwm`,
`/machine/soc/adc`, `/machine/soc/peci`, `/machine/soc/lpc` (`post-code`),
`/machine/peripheral/psu0..2`, `/machine/peripheral/rtc`.

The patches are made against QEMU 11.0.2, the version of the pinned OE-core; when
OE-core moves to another QEMU they need a refresh (the bbappend then fails at
`do_patch`).

PECI note: the CPU reports a Sapphire Rapids CPUID by default (`cpuid` 0x806f8),
because the peci-cpu driver of the pinned kernel (6.18) knows CPUs up to Emerald
Rapids and has no Granite Rapids-D entry.  With the real Xeon 6 GNR-D CPUID no CPU
or DIMM temperature appears, which is what the board will do until the kernel
learns that CPU.

## Notes

FRU: `ipmitool fru print/write 0` read and write the FRU EEPROM through
fru-device (ipmid's dynamic-sensors option), which only knows EEPROMs that
already hold a valid FRU.  The `ceb-gnrd-fru` package therefore writes a default
placeholder FRU into a blank EEPROM at boot (chassis type 0x17, which makes it FRU
ID 0), so a fresh `~/qemu-ceb-gnrd/fru0.bin` can be written with
`ipmitool fru write 0 fru.bin` straight away, and it asks fru-device to rescan
3 s after every FRU write so `ipmitool fru print 0` shows the new data.  To
re-seed the default image, delete `~/qemu-ceb-gnrd/fru*.bin` and restart QEMU.

Stock QEMU: there is no VUART, so UART3 (BMC ttyS2) stands in for the host serial
port on the same socket.  Only the running BMC is changed, a BMC reboot restores
the normal SOL on ttyVUART0:

```
systemctl stop obmc-console@ttyVUART0.service
obmc-console-server --config /etc/obmc-console/server.ttyVUART0.conf ttyS2 &
```

Stock QEMU also resets its whole GPIO model on a BMC reboot, so the power and
reset outputs read low for a while; `host-sim.py` then holds the last levels of
these pins after QEMU's RESET event until the BMC drives both power pins high
again, so a BMC reboot does not look like a host reset or a forced power off.

Environment for `run-qemu.sh`: `DEPLOY` (image directory, default
`~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd`), `STATE` (FRU EEPROM and
sockets, default `~/qemu-ceb-gnrd`), `BIOS_FLASH` (default `~/qemu-bios.bin`),
`QEMU`, `PANEL_PORT` (default 8800), `NO_PANEL`.
