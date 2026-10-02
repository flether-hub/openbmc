Ceb-gnrd (Intel Xeon 6, AST2600) OpenBMC board layer
================

This layer is nested under the top-level [meta-ctopai](../) vendor layer and
provides the machine definition and build templates for the ceb-gnrd board:
an ASPEED AST2600 BMC managing an Intel Xeon 6 (Granite Rapids) host.

Reference implementation: **meta-ibm/meta-sbp1** (Intel server platform).

Build usage:

    ./setup ceb-gnrd
    bitbake obmc-phosphor-image

How to build, run in QEMU, load images over TFTP and verify each feature is
described in `quick-start.md` (repository top level). The signal-by-signal
status of every item, with the doubtful ones marked in red, is in
`port_guide.xlsx`. Nothing in this README has been verified on real hardware
unless it says so; items that still need a board are listed under "Open items".

Platform features
-----------------

### Flash layout and upgrade

* BMC flash: W25Q512JVFIQ, 64 MiB on AST2600 Firmware SPI (FMC).
  `FLASH_SIZE = 65536`, `FLASH_RWFS_OFFSET:flash-65536 = "55296"`.

      u-boot        0x0000000  0xe0000
      u-boot-env    0x00e0000  0x20000
      kernel        0x0100000  9 MiB     (FIT: kernel, device tree, initramfs)
      rofs          0x0a00000  44 MiB    (squashfs)
      rwfs          0x3600000  10 MiB    (jffs2, settings)

  The Linux and U-Boot device trees must keep these offsets; `netupdate` in
  U-Boot (below) uses the same numbers.
* There is a single image bank. The web UI does not show a backup image.
* A normal firmware update does not clear `rwfs`. An update that does clear it
  keeps the whitelist in `recipes-phosphor/initrdscripts/files/ceb-gnrd-whitelist`
  (time zone, host name, SSH host keys, web certificates, fan settings). A
  factory reset clears everything. MAC addresses live in the U-Boot
  environment partition, which updates do not touch.

### U-Boot

* Default boot order (`bootcmd`, set in `recipes-bsp/u-boot/files/ceb-gnrd-netboot.cfg`):
  load `fitImage` from the TFTP server 192.168.185.84 to `0x83000000` and
  `bootm` it; if that fails (no link, no server, no file, image does not boot)
  fall through to `run bootspi`, the image in the local SPI flash. The TFTP
  timeouts are shortened so a missing server costs only a few seconds plus the
  fixed ARP timeout. The network image replaces only the kernel and initramfs;
  the root file system still comes from the local `rofs`.
* Default network settings equal Linux `eth0`: 192.168.185.200/24, gateway
  192.168.185.1, server 192.168.185.84 (patched into `aspeed-common.h` by the
  U-Boot bbappend; the build fails if the patch does not apply).
* `run netupdate` (variables in `recipes-bsp/u-boot/files/ceb-gnrd-env.h`)
  fetches `image-kernel` and `image-rofs` over TFTP and writes them with
  `sf update` to the kernel and rofs partitions after checking their size. It
  never writes U-Boot, the environment or `rwfs`.
* The environment is stored in flash, so a previously saved environment hides
  the new defaults: run `env default -a; saveenv` once (and set `ethaddr`, which
  is random otherwise).
* U-Boot uses only the RGMII port. The NC-SI MAC (`&mac2`) is disabled in the
  U-Boot device tree: with a `phy-mode` its probe crashes U-Boot (data abort and
  reset loop), without one it only prints "Invalid PHY interface".
* In QEMU the TFTP server is 192.168.185.1 (QEMU's `tftp=` option) instead of
  192.168.185.84, and the PHY/`mii` behaviour is emulated (RGMII timing and the
  RTL8211FS delays must be checked on the board).

### BIOS interaction (BIOS 菜单交互)

* **PLDM over MCTP** (`conf/distro/include/pldm.inc`): BIOS attribute tables
  and setup (menu) settings exposed through Redfish `Systems/system/Bios`,
  plus PLDM sensors and PLDM firmware update. Needs PLDM support in the BIOS.
* **biosconfig-manager**: view and modify BIOS setup parameters remotely via
  the BMC (see https://github.com/openbmc/bios-settings-mgr).
* **phosphor-host-postd + phosphor-post-code-manager**: BIOS POST code pipeline
  for I/O port 0x80. The AST2600 LPC snoop node is enabled for port 0x80;
  validate POST capture on hardware. LPC snoop is only a monitor, not the eSPI
  Peripheral I/O-cycle completion path.
* **phosphor-software-manager** with `flash_bios`: host BIOS update through
  the Macronix MX25U51245GMI00 (64 MiB) on AST2600 SPI1 in single-bit mode.
  If the host is on, the updater notifies through its service log and waits up
  to 30 minutes for a stable Off state; it never takes BIOS flash ownership
  while the host is running. It then selects BMC flash ownership with
  GPIOM1/NDCD1 as GPIO before locating the MTD (and retries SPI-NOR probe if
  needed), waits five seconds for the CPLD to place the CPU in S5, and flashes
  the full-chip `host-bios` MTD. Afterward it restores BIOS ownership and
  issues one ForceOff power-button pulse, then requests PowerOn. If the host is
  still On, the normal chassis Off request generates the configured 15-second
  override; if already Off/S5, a guarded board-specific method in
  x86-power-control generates that pulse without taking GPIO ownership away
  from the daemon. Confirm GPIO polarity and verify power sequencing on the
  assembled board.
* **phosphor-ipmi-flash**: IPMI in-band firmware update via BLOB protocol
  (host-bios targets enabled when `flash_bios` PACKAGECONFIG is active).
* **Host/chassis state management**: `MACHINE_FEATURES` includes
  `obmc-host-state-mgmt`, `obmc-chassis-state-mgmt`,
  `obmc-phosphor-chassis-mgmt`, `obmc-phosphor-flash-mgmt`. Host and chassis
  state come from `x86-power-control` (`power-config-host0.json`: PowerOk
  `BMC_CPU_PWRGD`, PowerOut `BMC_CPU_POWER_BUTTON`, ResetOut `BMC_CPU_RESET`,
  200 ms power pulse, 15 s force-off, 500 ms reset). Machine uses
  `obmc-bsp-common.inc` (managed server), not `obmc-evb-common.inc`.
* The chassis power button input `BMC_POWER_BUTTON_INPUT` is detect-only: a
  press is written to the SEL and the journal (`ceb-gnrd-power-button-log`). It
  neither starts a power transition nor passes through to the CPU power button
  output.
* What the Redfish side needs from the BIOS (boot progress over IPMI, one-time
  boot device through Get System Boot Options, SEL writes, SMBIOS hand-over for
  system/CPU/memory inventory, PLDM for `Bios`) is not provided by this layer;
  system, processor and memory inventory tables are therefore removed from the
  web UI.

### eSPI and host IPMI (KCS)

* The board wires AST2600 eSPI to the Xeon 6 host. GPIOW0-W7 are dedicated to
  this connection: `pinctrl_espi_default` covers W0-W5/W7 and the separate
  `pinctrl_espialt_default` covers W6/AD7; both are selected by the eSPI node.
  This board does not use Virtual Wire or Flash Access. OOB is not required for
  KCS/IPMI, POST code or UART3 SOL.
* The pinned `linux-aspeed` revision (`c0538446`) lacks the AST2600 eSPI
  controller driver. The board carries a focused driver
  (`0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch`; its
  Makefile line is added by `linux-aspeed_%.bbappend`) and enables
  `CONFIG_ASPEED_ESPI`. It enables only the Peripheral channel, asserts
  Peripheral Software Ready, resets the block and the peripheral channel on a
  host eSPI reset and sets ready again, counts channel errors/aborts, logs
  state changes (rate limited) and offers a debugfs `regs` dump. Check
  `dmesg | grep -i espi` first if the host cannot reach the BMC.
  `CONFIG_ASPEED_LPC_SIO` does not exist in this kernel and is not added.
* Peripheral I/O cycles are completed by the AST2600 hardware once Peripheral
  Ready is set; `ASPEED_LPC_SNOOP` is only the port 0x80 monitor.
* Host IPMI: ASPEED KCS BMC, IPMI and raw cdev options, `phosphor-ipmi-kcs`
  with its default `ipmi-kcs3` device. The device tree enables `&kcs3` with
  `aspeed,lpc-io-reg = <0xca2>`; the kernel driver does not probe without that
  property. No SerIRQ is configured (eSPI without virtual wires); the host
  polls the status register. The BIOS must set its BMC KCS port to 0xCA2.
* GPIOP7 (`BMC_HBLED#`) starts off. A board service enables the kernel LED
  heartbeat trigger once the eSPI Peripheral driver binds and sets `SW_READY`.

### PECI, temperatures and fan control

* AST2600 PECI0 is enabled for the BMC_CPU_PECI connection (package ball AT29).
  The kernel enables `CONFIG_PECI`, `CONFIG_PECI_CPU`, `CONFIG_PECI_ASPEED`,
  `CONFIG_SENSORS_PECI_CPUTEMP`, `CONFIG_SENSORS_PECI_DIMMTEMP`;
  `VIRTUAL-RUNTIME_obmc-sensors-hwmon = "dbus-sensors"` selects the
  IntelCPUSensor daemon. Only AST2600 I3C3 is enabled; DIMM temperature is read
  over PECI, not I3C.
* `ceb-gnrd-temp-max` (Python, dbus-fast) publishes two sensors,
  `/xyz/openbmc_project/sensors/temperature/CPU_MAX_TEMP` and `DIMM_MAX_TEMP`,
  as the maximum of the IntelCPUSensor temperatures (names containing "dimm"
  are DIMM; DTS, Tcontrol, Tthrottle, Tjmax and margin readings are excluded).
  Host off: 0. Host on and no reading: 70 degC, which both fan curves map to 60 % (no alarm).
  Upper thresholds only (non-critical / critical / non-recoverable):
  CPU 90 / 98 / 105 degC, DIMM 80 / 85 / 95 degC, on the Warning, Critical and
  HardShutdown threshold interfaces. The service emits `ThresholdAsserted`
  signals, which phosphor-sel-logger turns into SEL records. The discovered
  source sensor names are logged (`journalctl -u ceb-gnrd-temp-max`) and need
  checking on the board.
* Fans are driven by `phosphor-pid-control` from the Entity-Manager
  configuration (`ceb-gnrd.json`): six fan PID controllers (SYS_FAN0-5, outputs
  PWM1-PWM6, limit 30-100 %), one zone (MinThermalOutput 30) and two stepwise
  curves on CPU_MAX_TEMP and DIMM_MAX_TEMP. The curve points are placeholders
  awaiting confirmation. The zone fail-safe is 30 % on purpose: the number of
  fans that can be read must not decide the fan speed; the temperature
  sensors do that (unreadable CPU or DIMM temperature: 60 %). The six fans have no speed alarms and
  an unpopulated header simply reads 0 RPM.
* `ceb-gnrd-fan-owner` hands the fans from the CPLD to the BMC
  (GPIOI6 `BMC_FAN_BMC_OVERRIDE_N`) once pid-control is running and all six
  PWM/TACH channels exist, and returns them when pid-control stops.
* `ceb-gnrd-fan-settings` backs the web UI fan page (per-fan or common limits,
  optional persistence across BMC restarts in `/var/lib/ceb-gnrd`); it
  re-applies the stored limits to the Entity-Manager Pid objects every 30 s.
  The page talks to it through bmcweb's `dbus-rest` option.

### RTC and log time

* The NCT3015Y-R is on AST2600 I2C10 (Linux `i2c-9`, address `0x6f`) and is
  bound with the `nuvoton,nct3018y` driver (register compatibility with the
  NCT3015Y is not verified on hardware). The AST2600 internal RTC has no
  battery, so it is disabled in the device tree and the NCT3015Y is `rtc0`.
* The BMC system time, and with it the SEL and journal timestamps, comes from
  the RTC by default: `CONFIG_RTC_HCTOSYS` at boot, with `ceb-gnrd-rtc-sync` as
  a safety net (waits up to 30 s for `/dev/rtc0`, so a machine without an RTC,
  such as QEMU, waits the full 30 s). `CONFIG_RTC_SYSTOHC` writes the time back
  after NTP sync. Keep the RTC in UTC.

### Board hardware map

The workbook-derived map is installed as
`/usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml`. It records the 16 I2C
buses, the CPU I3C3 management bus, AST2600 ADC pads 0-15, six PWM/TACH fan
channels and the named power, reset and alert GPIOs. Chassis-open detection
uses the AST2600 dedicated CHASI# intrusion input through the intrusion hwmon
latch (`0002-hwmon-add-AST2600-chassis-intrusion-driver.patch`).

* Four NST175H-QSPR temperature sensors on I2C7 (Linux `i2c-6`): inlet `0x48`,
  outlet `0x49`, PCIe `0x4a`, M.2 `0x4b`, measurement only.
* ADC: both ADC engines use the 2.5 V internal reference. `D3V0_BAT0` is
  read as built (R542/Q39 not populated, so the 3 V battery saturates the
  input) until the schematic is corrected.
* CRPS power supplies: schematic I2C8 (Linux `i2c-7`), PMBus addresses
  `0x58`/`0x59`/`0x5a`, 0 to 2 modules installed. The device tree declares no
  PMBus nodes: `ceb-gnrd-psu-detect` polls the three addresses every 5 s with a
  STATUS_BYTE read and creates or deletes the pmbus device for each module, so
  empty slots log no probe failures. Entity-Manager/PSUSensor publishes input
  and output voltage and power plus `PSUn_Temp` (pmbus `temp2`). No presence,
  redundancy or threshold alarm is configured.
* CPU PROM/SMBUS_HOST: `BMC_PROM_SCL/SDA` on AST2600 I2C15 (Linux `i2c-14`); no
  EEPROM client is created.
* Board revision: `PCB_VER[2:0]` are sampled as GPIO inputs; see the end of
  this file.

### BMC network ports

* `eth0`: MAC2 with RTL8211FS-CG on the independent management RJ45, static
  IPv4 `192.168.185.200/24`, gateway `192.168.185.1`, DNS `192.168.185.1`,
  `223.5.5.5`, `223.6.6.6`. RGMII mode `rgmii` (the PHY adds no delay, RXDLY
  strap off), PHY address 2 per the schematic note (the strap resistors read 1;
  confirm on the board), PHY reset RTL8211_SYS_RSTN is driven by the CPLD. The
  RGMII delays still need checking on the board.
* `eth1`: MAC3 NC-SI to the Intel E810 (IPMI LAN channel 2), DHCP. The E810
  has no standby power, so `ceb-gnrd-ncsi` keeps the link down while the host
  is off, raises it when the chassis power state becomes On and, because the
  E810 may not answer immediately, cycles the link every 30 s up to three times
  while there is no carrier. systemd-networkd does not change the
  administrative state of this interface itself (`ActivationPolicy=manual`).

The Linux and U-Boot device trees keep this mapping: phandle `mac1` is
physical MAC2 (RTL8211FS, `mdio1`/`ethphy1`), phandle `mac2` is physical MAC3
(NCSI3, E810); physical MAC1 and MAC4 are disabled. Only these two devices
should appear after flashing the updated image.

### Alerts, SEL and the system alert LED

* One shared LED, `BMC_SYS_ALERT_LED` (GPIOI5), shows four alarms
  (`ceb-gnrd-alert-led`): a voltage threshold alarm and a temperature upper
  critical alarm (or the higher non-recoverable one) go out when the alarm
  clears; a host watchdog timeout and a BIOS boot failure (`BMC_BIOS_BOOT_OK`
  not asserted within 600 s of power good) stay latched until the BMC is
  rebooted. Any of them lights the LED.
* All four are written to the SEL: voltages and temperatures by
  phosphor-sel-logger's threshold monitor (a board patch,
  `0001-ceb-gnrd-log-non-recoverable-threshold-events.patch`, makes it handle
  the HardShutdown level as upper/lower non-recoverable), the watchdog by its
  watchdog monitor and the BIOS failure by the alert service itself.
* The SEL is a rollover log: `ceb-gnrd-sel-rollover` keeps the newest 2000
  records of `/var/log/ipmi_sel` and drops the oldest when it grows past 2100
  (it may lose a record that arrives during the trim). Whether `/var/log`
  survives a reboot is not checked.
* The web event log is fed from the SEL through the journal records of
  sel-logger.

### IPMI

* `mc info`: Device ID 32, Device Revision 2, Product ID 3346 (0x0D12),
  Manufacturer ID 6659 (0x1A03), shown as `CTOPAI` / `CEB-GNR-D` by the
  on-BMC ipmitool. The board revision is the fourth AUX firmware revision byte.
  Firmware revision comes from `DISTRO_VERSION` (1.0.0, tentative).
* Sensors: `dynamic-sensors` and `hybrid-sensors` are enabled, so every D-Bus
  sensor (ADC, temperatures, fans, CPU/DIMM maximum, PSU) is visible through
  IPMI next to the static host-state sensors. In QEMU only the two static
  sensors that have D-Bus objects appear.
* LAN: `phosphor-ipmi-net` serves RMCP+ on `eth0`. SOL, user, channel and
  session commands use the standard phosphor-host-ipmid providers.
* DCMI power reading and temperature reading are not configured
  (`power_reading.json` has no path, `dcmi_sensors.json` is empty), so those
  commands return nothing useful.
* SSH is dropbear (port 22); `openssh-sftp-server` and `openssh-scp` are
  installed, so `scp` works with both the SFTP-based and the legacy protocol.

### Web UI

* Languages: English (`en-US`) and Simplified Chinese (`zh-CN`); the others
  are filtered out, including stale saved selections. `zh-CN.json` is a full
  translation maintained in this layer.
* The web UI is patched at build time (`recipes-phosphor/webui/files`, listed in
  `webui-vue_%.bbappend`): languages (0001-0002), fan control page (0003),
  removal of SNMP, key clear, LDAP and the resource-management power page
  (0004), read-only SOL (0005), KVM full screen (0006), BMC-only factory reset
  (0007), inventory limited to system, BMC and chassis (0008), removal of the
  overview power card (0009), no backup image card (0010) and BMC dump only
  (0011).
* bmcweb is built with `dbus-rest` (fan page) and `redfish-dump-log` (dump page;
  the recipe leaves the dump routes out otherwise). `phosphor-debug-collector`
  produces the BMC dumps. There is no System dump on this platform.
* Virtual media: only "read image from the browser" is supported
  (bmcweb `/vm/0/0` WebSocket, jsnbd, nbd, USB mass storage through the vHub to
  the host). The external-server (CIFS/HTTPS) mode needs the discontinued
  virtual-media service and is neither built nor shown.
* The BIOS card on the firmware page shows `--` for the running version; BIOS
  version reporting is not implemented.
* The overview "power information" card, power cap and anything that needs
  DCMI power support are removed.

### VGA display output and KVM

* AST2600 GFX DAC output provides the CPU's VGA display path
  (`CONFIG_DRM_ASPEED_GFX`, `&gfx`, GPIOL6/VGAHS and GPIOL7/VGAVS). DDC pins are
  fixed-function.
* The separate `CONFIG_VIDEO_ASPEED` / `&video` path (reserved memory
  `video_engine_memory`) captures host video for KVM; the image has
  `obmc-ikvm` and the bmcweb KVM endpoint. AST2600 USB2A D+/D- goes to host
  VL805 USB port 4: the vHub runs in device mode (`pinctrl_usb2ad_default`),
  EHCI host mode is disabled and configfs HID provides the keyboard and mouse.

### Host serial-over-LAN

* SOL is receive-only. The CPU serial output is cross-connected to AST2600 UART3
  RX (`GPIOL5/RXD3`); only RX is muxed (`pinctrl_rxd3_default`), `GPIOL4/TXD3`
  is left undriven, so nothing typed in the web, SSH or IPMI SOL reaches the
  host. The web page says so and disables terminal input.
* `obmc-console` uses `ttyS2` (UART3) as `OBMC_CONSOLE_HOST_TTY` with the port
  specific `server.ttyS2.conf` (115200 baud, default socket name so bmcweb and
  IPMI SOL connect). The BIOS serial redirection must use 115200 as well.
* UART5 (`ttyS4`, 115200 baud, balls C8/D8) is the local BMC debug console;
  U-Boot and Linux use it.

### FRU EEPROM access

* **fru-device** (entity-manager) probes I2C for FRU EEPROMs and publishes
  them on D-Bus.
* **phosphor-ipmi-fru** is wired to the FM24C08D on schematic I2C11 (Linux
  `i2c-10`), address blocks `0x50`-`0x53`, 1 KiB with 16-byte pages. The
  schematic shows a pulldown on `BMC_FRU_WP` (package ball D21, GPIOG6), so
  writes are enabled by default.
* `ceb-gnrd-yaml-config.bb` provides the FRU YAML mapping files
  (`IPMI_FRU_YAML` / `IPMI_FRU_PROP_YAML`); the entity ID and instance are 0.

Open items
----------

Everything here needs a board (or is waiting for your decision):

* eSPI peripheral channel bring-up and the BIOS KCS port (0xCA2).
* PHY address 2, RGMII delays and U-Boot/Linux network on the real board.
* NC-SI link timing after host power-on (retry interval and count are guesses).
* PSU STATUS_BYTE probing, `temp2` as the PSU temperature, PSU sensor naming.
* The names IntelCPUSensor gives the CPU and DIMM temperatures (used by
  `ceb-gnrd-temp-max`) and the fan PWM object names.
* Fan curve temperatures (placeholders), the IANA manufacturer ID (0x1A03 as
  given), firmware version rule.
* Real-hardware checks of SEL records for each alarm, SEL rollover, the RTC
  as time source, SOL output and KVM.
* BIOS version reporting (sbp1's coreboot-based `bios-version` does not apply
  to a UEFI BIOS), SMBIOS-based inventory and DCMI are not implemented.
* `D3V0_BAT0` scaling once R542/Q39 are populated.

Board revision in IPMI
----------------------

The three `PCB_VER[2:0]` strap inputs are sampled as GPIO inputs. Their raw
logic levels encode the board revision as `(PCB_VER2 << 2) | (PCB_VER1 << 1) |
PCB_VER0`, producing a value from 0 to 7. `ipmitool mc info` reports this value
in the fourth (last) byte of the AUX Firmware Revision field. The first three
AUX bytes remain unchanged. `CFG_VER0` is a separate configuration strap, and
`CFG_VER1` is reserved; neither is included in the PCB revision.

The AST2600 is an ARM, service management SOC made by ASPEED. More information
about the AST2600 can be found
[here](http://aspeedtech.com/server_ast2600/).
