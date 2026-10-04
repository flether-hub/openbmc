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
* A firmware update (`*.static.mtd.tar`: image-u-boot, image-kernel,
  image-rofs, image-rwfs) is staged in `/run/initramfs` and written by the
  initramfs update script when the BMC reboots:
  * kernel and rofs are replaced;
  * rwfs is rewritten, and only the files of the OpenBMC whitelist (users and
    passwords, IPMI password, network, DNS, settings) and of
    `recipes-phosphor/initrdscripts/files/ceb-gnrd-whitelist` (time zone, host
    name, SSH host keys, web certificates, fan settings) are restored; the SEL
    and event logs are lost;
  * U-Boot is **not** rewritten (`ceb-gnrd-update-skip-u-boot.sh`, a power loss
    while it is written would leave a board that does not boot); create
    `/run/initramfs/update-u-boot` before the reboot to update it on purpose;
  * the U-Boot environment (MAC addresses) is not part of the package.

  A factory reset clears everything in rwfs.

### U-Boot

* Boot order: `bootcmd` is fixed to `run bootspi`, the FIT image in the local SPI flash; U-Boot never loads the system over the network by itself. TFTP is only used by hand: `tftpboot 0x83000000 fitImage` and `bootm` for kernel debugging (the root file system still comes from the local `rofs`), and by `run netupdate` below.
* Default network settings equal Linux `eth0`: 192.168.185.200/24, gateway
  192.168.185.1, server 192.168.185.84 (set in `aspeed-common.h` by
  `0001-ceb-gnrd-board-device-tree-network-and-environment.patch`, which also
  registers the device tree and adds the board environment to the default one).
* `run netupdate` (variables in `recipes-bsp/u-boot/files/ceb-gnrd-env.h`)
  fetches `image-kernel` and `image-rofs` over TFTP and writes them with
  `sf update` to the kernel and rofs partitions after checking their size. It
  never writes U-Boot, the environment or `rwfs`.
* The environment is stored in flash, so a previously saved environment (for example an older `bootcmd` that tried TFTP first) hides the new defaults: run `env default -a; saveenv` once (and set `ethaddr`, which
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
  still On, the normal chassis Off request generates the configured 8-second
  override; if already Off/S5, a guarded board-specific method in
  x86-power-control generates that pulse without taking GPIO ownership away
  from the daemon. Confirm GPIO polarity and verify power sequencing on the
  assembled board.
  Only selected flash regions are written (`flashrom -l <layout> -i <region>`,
  which also skips unchanged blocks); the other regions keep their content.
  The layout is fixed for the board: `/usr/share/ceb-gnrd/bios-layout.txt`
  (descriptor, metadata, pdr, bios, nac1, nac0, reserved; the web page has the
  same table).  The regions come from `bios-regions.txt` in the
  package, which the web firmware page adds from its check boxes; without it
  (curl, Redfish clients) every region except nac0/nac1 is written.  nac0/nac1
  hold the CPU's integrated network controller settings and MAC addresses; the
  web page selects them only after a confirmation dialog.  The image must be
  the full 64 MiB flash image.
  Each step writes a percentage to the update's
  `ActivationProgress` object, bmcweb turns it into the PercentComplete of the
  Redfish update task, and the web firmware page (patch 0013) shows a progress
  bar with the step name; the numbers are listed in `bios-update.sh` and must
  match the table in that patch.
* **phosphor-ipmi-flash**: IPMI in-band firmware update via BLOB protocol
  (host-bios targets enabled when `flash_bios` PACKAGECONFIG is active).
* **Host/chassis state management**: `MACHINE_FEATURES` includes
  `obmc-host-state-mgmt`, `obmc-chassis-state-mgmt`,
  `obmc-phosphor-chassis-mgmt`, `obmc-phosphor-flash-mgmt`. Host and chassis
  state come from `x86-power-control` (`power-config-host0.json`: PowerOk
  `BMC_CPU_PWRGD`, PowerOut `BMC_CPU_POWER_BUTTON`, ResetOut `BMC_CPU_RESET`,
  200 ms power pulse, 8 s force-off, 500 ms reset). Machine uses
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
  The Peripheral and Virtual Wire channels are enabled (the host, an Intel PCH,
  always uses Virtual Wire); Flash Access is not used. OOB is not required for
  KCS/IPMI, POST code or the VUART SOL (the VUART is configured by the BMC).
* The pinned `linux-aspeed` revision (`c0538446`) lacks the AST2600 eSPI
  controller driver. The board carries a focused driver
  (`0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch`; its
  Makefile line is part of the same patch) and enables
  `CONFIG_ASPEED_ESPI`. It enables the Peripheral and Virtual Wire channels:
  it asserts Peripheral and Virtual Wire Software Ready and the slave boot
  done / status system events (`ESPI098` bits 20 and 23, which the host
  waits for), resets the block on a host eSPI reset and sets all of that again
  (the wires themselves, GPIO and system events, stay in hardware mode, there
  is no software mode and no Virtual Wire interrupt), counts channel errors/aborts, logs
  state changes (rate limited) and offers a debugfs `regs` dump. Check
  `dmesg | grep -i espi` first if the host cannot reach the BMC.
  `CONFIG_ASPEED_LPC_SIO` does not exist in this kernel and is not added.
* Peripheral I/O cycles are completed by the AST2600 hardware once Peripheral
  Ready is set; `ASPEED_LPC_SNOOP` is only the port 0x80 monitor.
* Host IPMI: ASPEED KCS BMC, IPMI and raw cdev options, `phosphor-ipmi-kcs`
  with its default `ipmi-kcs3` device. The device tree enables `&kcs3` with
  `aspeed,lpc-io-reg = <0xca2>`; the kernel driver does not probe without that
  property. No SerIRQ is configured for KCS: the host polls the status
  register. The BIOS must set its BMC KCS port to 0xCA2.
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
  CPU 90 / 98 / 105 degC, DIMM 80 / 85 / 95 degC.  The first two use the Warning
  and Critical threshold interfaces; the non-recoverable one is on a private
  interface (`com.ctopai.CebGnrd.Threshold.NonRecoverable`), never on
  HardShutdown: the BMC must not shut the system down because of a threshold,
  and services such as phosphor-fan's sensor monitor power the system off on a
  HardShutdown alarm (that monitor is also removed from the image).  The service
  emits `ThresholdAsserted` signals, which phosphor-sel-logger turns into SEL
  records; a board patch of ipmid shows the non-recoverable value as UNR. The discovered
  source sensor names are logged (`journalctl -u ceb-gnrd-temp-max`) and need
  checking on the board.
* Fans are driven by `phosphor-pid-control` from the Entity-Manager
  configuration (`ceb-gnrd.json`): six fan PID controllers (Fan0 Control to Fan5 Control, inputs SYS_FAN0-5, outputs
  PWM1-PWM6, limit 30-100 %), one zone (MinThermalOutput 30) and two stepwise
  curves on CPU_MAX_TEMP and DIMM_MAX_TEMP. The curve points are placeholders
  awaiting confirmation. The zone fail-safe is 30 % on purpose: the number of
  fans that can be read must not decide the fan speed; the temperature
  sensors do that (unreadable CPU or DIMM temperature: 60 %). The six fans have no speed alarms and
  an unpopulated header simply reads 0 RPM.  The Pid objects must not share a
  name with the AspeedFan objects (SYS_FAN0-5): both would get one D-Bus path and
  writes to the Pid properties fail.  Stepwise `Reading`/`Output` arrays are
  written with a decimal point (`40.0`) because pid-control cannot read the
  unsigned-integer arrays Entity-Manager publishes for `40`.
* `ceb-gnrd-fan-owner` hands the fans from the CPLD to the BMC
  (GPIOI6 `BMC_FAN_BMC_OVERRIDE_N`) once pid-control is running and all six
  PWM/TACH channels exist, and returns them when pid-control stops.
* `ceb-gnrd-fan-settings` backs the web UI fan page (per-fan or common limits,
  optional persistence across BMC restarts in `/var/lib/ceb-gnrd`); it
  re-applies the stored limits to the Entity-Manager Pid objects every 30 s.
  Adaptive mode uses fixed limits (30 % to 100 %); there is no minimum-speed
  setting.  Entity-Manager answers a write to a Pid property with InvalidArgs
  although the value is changed (root cause not pursued), so the service reads the value
  back and accepts it when it matches.  bmcweb's D-Bus REST cannot pass scalar
  arguments in this version, so the page calls argument-free methods in three
  steps: `SelectAll` / `SelectFan0..5`, `SetAdaptive` / `SetFixed20..100`, then
  `KeepSettings` / `ForgetSettings`.
* The same control is exposed as two IPMI OEM commands, netfn 0x30:
  `0x01` Get (flag byte, then mode/duty/RPM-low/RPM-high for SYS_FAN0..5, 25
  bytes, duty `0xFF` = unknown) and `0x02` Set (fan 0-5 or 0xFF, mode, duty,
  persist; Admin).  They are implemented by the `ceb-gnrd-ipmi-fan` ipmid provider
  (pulled in by `ceb-gnrd-ipmi`) and whitelisted in `ceb-gnrd-ipmi-whitelist.conf`.
  Checked in QEMU with `ceb-gnrd-check` (set, read back, keep, clear, invalid
  fan); not checked on the board.

### Boot, ipmid start and board self-check

* The AST2600 SD/eMMC controllers are disabled in the U-Boot and Linux device
  trees (the EVB include enables them); the board has neither.
* Hardware watchdog: WDT1 resets the SoC only (`aspeed,reset-type = "soc"`, not
  the whole chip, so GPIOs keep their state; check on the board).  systemd feeds it
  (`RuntimeWatchdogSec=120s`).  `aspeed_wdt` has no pre-timeout, so `systemd-conf`
  installs a `40-hardware-watchdog.conf` with the same name as meta-phosphor's
  (the one in /etc wins) that keeps only `RuntimeWatchdogSec=120s` and drops
  `RuntimeWatchdogPreSec` / `RuntimeWatchdogPreGovernor=panic` (otherwise systemd
  logs "Failed to set watchdog pretimeout_governor" at every boot; clearing them
  with an empty assignment is rejected by systemd).
* A kernel oops becomes a panic (`CONFIG_PANIC_ON_OOPS`) and a panic restarts the
  BMC after 5 s (`CONFIG_PANIC_TIMEOUT=5`).  Magic SysRq is enabled (not from the
  serial BREAK) so that `echo c > /proc/sysrq-trigger` can test this.
* Service recovery uses the standard systemd / OpenBMC mechanisms
  (`ceb-gnrd-health`).  This layer's own fan-settings, temp-max and alert-led
  services get a drop-in with `Restart=always` and a start limit (5 starts in 5
  minutes) and nothing else: systemd runs `OnFailure=` at every failure, also one
  that is followed by an automatic restart (seen on the VM: one SIGKILL of
  temp-max quiesced and rebooted the BMC), so they must not have it.  The object
  mapper, Entity-Manager, bmcweb and ipmid get the same plus
  `OnFailure=obmc-bmc-service-quiesce@0.target`, so the first failure of one of
  them (it is restarted too, but the BMC reboots anyway) makes
  phosphor-state-manager put the BMC into Quiesced; the option
  `auto-reboot-on-bmc-quiesce` (`phosphor-state-manager_%.bbappend`) then reboots
  it.  Upstream puts no limit on these reboots; `ceb-gnrd-quiesce-reboot-limit.sh`
  (ExecCondition of `phosphor-bmc-quiesce-reboot.service`) allows at most 1
  automatic reboot, counted in the read-write flash and cleared 15 minutes after a
  boot by `ceb-gnrd-quiesce-reboot-clear.timer`.  If the fault is still there
  after that reboot the BMC stays Quiesced (a SEL record is written) for manual
  recovery.  The upstream daemons do not ping the systemd watchdog,
  so only crashes are recovered for them (a hang that keeps the process alive is
  not).  This layer's own services are `Type=notify` with `WatchdogSec=` and
  ping from their main loop, so a hang restarts them.
  `ceb-gnrd-wdt-reset-log` writes a SEL record when `bootstatus` shows a
  watchdog reset without the clean-shutdown marker (a `reset` typed in U-Boot is
  also reported once).  Neither has been built or run yet.
* `phosphor-ipmi-host` has a drop-in (`10-ceb-gnrd-wait-sensors.conf`) that waits
  up to 90 s until the number of D-Bus sensors has been stable for 8 s.  Started
  earlier, ipmid read the sensors before their threshold interfaces existed and
  offered only the two static sensors for the first minute.  Cost: `ipmitool`
  is not available for about a minute after boot.
* `ceb-gnrd-check` (`recipes-phosphor/utils`, installed to `/usr/bin`) runs on
  the BMC, prints PASS/FAIL for services, sensors and thresholds, IPMI commands,
  the fan OEM commands, Redfish, RTC and MTD layout and bundles logs into
  `/tmp/ceb-gnrd-check.tar.gz`.  Its expected values are those of the QEMU run.
  Known FAIL there: Manager `FirmwareVersion` (see the bmcweb note above).
* `bmc-hw-dump` (`recipes-phosphor/utils/files/bmc-hw-dump.sh`, installed to
  `/usr/bin`) is a read-only dump of how the running firmware uses the hardware
  (GPIO, pin mux, I2C, eSPI/KCS/VUART, network, flash, ...).  Copy the script to
  the old vendor firmware and run it there, run `bmc-hw-dump` on this firmware,
  then compare on the PC with `sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz`.
  `ceb-gnrd-checklist.txt` in the dump lists every ceb-gnrd hardware function
  with the expected and the found value.

### Alignment with OpenBMC conventions

* x86 platform setup follows the Intel reference platform: `obmc-host-ctl` is not
  a machine feature (its only provider is OpenPOWER's `obmc-op-control-host`) and
  `VIRTUAL-RUNTIME_obmc-discover-system-state` is `x86-power-control`, which also
  applies the power restore policy at BMC boot.
* Private D-Bus names use the vendor domain: services and interfaces are
  `com.ctopai.CebGnrd.*` (`FanSettings`, `TempMax`, `Threshold.NonRecoverable`).
  The fan settings object path stays `/xyz/openbmc_project/ceb_gnrd/fan_settings`
  because the bmcweb D-Bus REST API only serves object paths under `/xyz` and
  `/org`.
* Changes to upstream sources are patch files, not `sed`: U-Boot
  (`0001-ceb-gnrd-board-device-tree-network-and-environment.patch`), the kernel
  Makefile line (inside the eSPI patch), ipmitool's product name
  (`0002-ipmitool-add-ceb-gnrd-product-name.patch`).  The x86-power-control and
  ipmid patches were regenerated against the pinned sources, so the `patch-fuzz`
  QA downgrade is gone.  The ipmitool manufacturer name (IANA enterprise number
  6659) still comes from a line added to the installed `enterprise-numbers` data
  file in `do_install:append`, because that file is not part of the ipmitool source.
* `DISTRO_VERSION` is defined in the vendor distro `ctopai-openbmc`
  (`meta-ctopai/conf/distro`); `local.conf` must select it (`./setup ceb-gnrd`
  migrates an old `DISTRO ?= "openbmc-phosphor"`).  The board hardware contract is
  installed through `MACHINE_EXTRA_RDEPENDS`, not a machine feature.
* Not changed on purpose: bmcweb keeps `redfish-updateservice-use-dbus=disabled`
  and phosphor-software-manager keeps the classic updater
  (`software-update-dbus-interface` removed, BMC updater enabled by a symlink).
  The default flow replaces `xyz.openbmc_project.Software.BMC.Updater` by
  `Software.Manager` and the BIOS update here (`bios-update.sh`,
  `obmc-flash-host-bios@.service`) is built on the classic flow, so switching
  needs the BIOS update re-done and tested on the board.
* None of this was built or run.
### RTC and log time

* The NCT3015Y-R is on AST2600 I2C10 (Linux `i2c-9`, address `0x6f`) and is
  bound with the `nuvoton,nct3018y` driver (register compatibility with the
  NCT3015Y is not verified on hardware). The AST2600 internal RTC has no
  battery, so it is disabled in the device tree and the NCT3015Y is `rtc0`.
* The BMC system time, and with it the SEL and journal timestamps, comes from
  the RTC by default: `CONFIG_RTC_HCTOSYS` at boot, with `ceb-gnrd-rtc-sync` as
  a safety net (waits up to 3 s for `/dev/rtc0`, so a machine without an RTC,
  such as QEMU, waits the full 3 s; start timeout 5 s). `CONFIG_RTC_SYSTOHC` writes the time back
  after NTP sync. Keep the RTC in UTC.

### Board hardware map

The workbook-derived map is installed as
`/usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml`. It records the 16 I2C
buses, the CPU I3C3 management bus, AST2600 ADC pads 0-15, six PWM/TACH fan
channels and the named power, reset and alert GPIOs. Chassis-open detection
uses the AST2600 dedicated CHASI# intrusion input through the intrusion hwmon
latch (`0002-hwmon-add-AST2600-chassis-intrusion-driver.patch`).

* Four NST175H-QSPR temperature sensors on I2C7 (Linux `i2c-6`): inlet `0x48`,
  outlet `0x49`, PCIe `0x4a`, M.2 `0x4b`, measurement only.  They are created by
  Entity-Manager / dbus-sensors (Type `LM75A`), not declared in the device tree
  (declaring them in both places logged `Failed to register i2c client lm75a ...
  (-16)` at every scan).
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

* One shared LED, `BMC_SYS_ALERT_LED` (GPIOI5, kernel LED label `fault`),
  shows four alarms (`ceb-gnrd-alert-led`).  It is driven by phosphor-led-manager:
  the service only asserts / de-asserts the standard `enclosure_fault` group
  (`Asserted` property, re-sent every 30 s while alerting) and `led.json` maps
  the group to the `fault` LED.  A voltage threshold alarm and a temperature
  upper non-recoverable (UNR) alarm go out when the alarm clears; a temperature
  upper critical alarm alone does not light the LED; a host watchdog timeout and a BIOS boot failure (`BMC_BIOS_BOOT_OK`
  not asserted within 600 s of power good) stay latched until the BMC is
  rebooted. Any of them lights the LED.  The service reads no GPIO itself: the
  host power state comes from `xyz.openbmc_project.State.Chassis`
  `CurrentPowerState` and BIOS boot OK from `OperatingSystemState`
  (`xyz.openbmc_project.State.OperatingSystem`, `/xyz/openbmc_project/state/host0`);
  x86-power-control holds both lines (`PowerOk` `BMC_CPU_PWRGD`, standard
  `PostComplete` `BMC_BIOS_BOOT_OK`, high active) exclusively.  A falling
  `PostComplete` edge while the host is on starts the warm-reset check of its
  state machine and records a soft-reset restart cause; it sends no power pulse.
  Not run on the board.
* All four are written to the SEL: voltages and temperatures by
  phosphor-sel-logger's threshold monitor (a board patch,
  `0001-ceb-gnrd-log-non-recoverable-threshold-events.patch`, makes it handle
  the private NonRecoverable interface as upper/lower non-recoverable), the watchdog by its
  watchdog monitor and the BIOS failure by the alert service itself.
* rsyslog loads `imjournal` (`recipes-extended/rsyslog/rsyslog_%.bbappend`): without
  it rsyslog never sees the `IPMI_SEL_*` journal fields and `/var/log/ipmi_sel`
  stays empty (the SEL then reads "no entries" although sel-logger logs events).
* The web "Event logs" page is the Redfish event log, which is a different file
  from the IPMI SEL: bmcweb reads `/var/log/redfish` (lines `<timestamp>
  <MessageId>,<MessageArgs>`, only message IDs known to its registry), and rsyslog
  writes it from journal entries that carry a `REDFISH_MESSAGE_ID`
  (`ceb-gnrd-redfish.conf`, same rule as the Intel reference platform;
  sel-logger's threshold events and the power-button message have one).  Without
  that rule the page stays empty although `ipmitool sel list` has records.
  `redfish` is rotated by the same logrotate run as the SEL (64k, one old file).
* The SEL is a rollover log kept with the standard logrotate
  (`ceb-gnrd-sel-logrotate`): phosphor-sel-logger reads `/var/log/ipmi_sel*` (all
  rotated files) and keeps the next record ID in a file of its own, so IDs are
  never reused.  A timer runs logrotate every 5 minutes with `size 15k` and
  `rotate 1`, i.e. about the newest 100 to 200 records are kept and older ones
  are deleted (size based, so the count is approximate; a burst of records can
  exceed it for up to 5 minutes).  Whether `/var/log` survives a reboot is not
  checked.
* The web event log is fed from the SEL through the journal records of
  sel-logger.

### IPMI

* `mc info`: Device ID 32, Device Revision 2, Product ID 3346 (0x0D12),
  Manufacturer ID 6659 (0x1A03), shown as `CTOPAI` / `CEB-GNR-D` by the
  on-BMC ipmitool. The board revision is the fourth AUX firmware revision byte.
  Firmware revision comes from `DISTRO_VERSION`, set in the vendor distro `meta-ctopai/conf/distro/ctopai-openbmc.conf` (`DISTRO = "ctopai-openbmc"` in `local.conf`; 2.0.0; the firmware version starts at 2.0, shown as 2.00 by `ipmitool mc info`).
* Sensors: `dynamic-sensors` and `hybrid-sensors` are enabled, so every D-Bus
  sensor (ADC, temperatures, fans, CPU/DIMM maximum, PSU) is visible through
  IPMI next to the static host-state sensors. In QEMU only the two static
  sensors that have D-Bus objects appear.
* Voltage thresholds (nominal +-15 %) use the Critical level (lower critical / upper critical) so that ipmitool shows them; the Entity-Manager board is named "CEB-GNRD" (Redfish chassis "CEB_GNRD").
* LAN: `phosphor-ipmi-net` serves RMCP+ on `eth0`. SOL, user, channel and
  session commands use the standard phosphor-host-ipmid providers.
* DCMI power reading and temperature reading are not configured
  (`power_reading.json` has no path, `dcmi_sensors.json` is empty), so those
  commands return nothing useful.
* `ipmitool fru gen [file]` (a board patch to ipmitool) interactively builds a FRU image (default `fru.bin`) with chassis, board and product info areas: each prompt shows the format and a placeholder default. Write it with `ipmitool fru write 0 fru.bin`.
* SSH is dropbear (port 22); `openssh-sftp-server` and `openssh-scp` are
  installed, so `scp` works with both the SFTP-based and the legacy protocol.

### Web UI

* Languages: English (`en-US`) and Simplified Chinese (`zh-CN`); the others
  are filtered out, including stale saved selections. `zh-CN.json` is a full
  translation maintained in this layer.
* The web UI is patched at build time (`recipes-phosphor/webui/files`, listed in
  `webui-vue_%.bbappend`): languages (0001-0002), fan control page (0003),
  removal of SNMP, key clear, LDAP and the resource-management power page
  (0004), KVM full screen (0006), BMC-only factory reset
  (0007), inventory limited to system, BMC and chassis (0008), removal of the
  overview power card (0009), no backup image card (0010) and BMC dump only
  (0011), no Virtual TPM / RTAD switches (0012).  The firmware page has no
  backup image card for the BMC and for the BIOS (0010).
* bmcweb is built with `dbus-rest` (fan page), `redfish-dump-log` (dump page;
  the recipe leaves the dump routes out otherwise) and
  `redfish-updateservice-use-dbus=disabled`: with the default the Manager
  `FirmwareVersion` is looked up under `/xyz/openbmc_project/software/bmc/functional`,
  while the classic phosphor-image-updater used here publishes
  `/xyz/openbmc_project/software/functional` (not verified after the change). `phosphor-debug-collector`
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

* SOL uses the AST2600 VUART1: the host sees it as COM1 (I/O `0x3F8`) over the
  eSPI Peripheral channel, so it is bidirectional (`&vuart1` in the device tree,
  `CONFIG_SERIAL_8250_ASPEED_VUART`). `obmc-console` uses `ttyVUART0` (symlink
  from `udev-aspeed-vuart`, VUART1 at `0x1E787000`) as `OBMC_CONSOLE_HOST_TTY`
  with `server.ttyVUART0.conf` (default socket name so bmcweb and IPMI SOL
  connect). The BIOS serial redirection must be set to COM1.
* Why VUART: the BIOS detected the AST2600 SuperIO, routed COM1 to eSPI and
  polled the line status register `0x3FD` forever; with no working COM1 behind
  it the register read `00` ("transmitter not empty") and the BIOS hung. A running
  VUART answers that register. Something must read the VUART data (obmc-console
  does), or its buffer fills, the register goes back to "not empty" and the BIOS
  can hang again.
* UART3 RX (`GPIOL5/RXD3`, receive-only) stays muxed but is no longer the SOL
  source. The web SOL page is the stock one (typing is allowed); the old read-only
  patch `0005` was removed.
* The AST2600 SuperIO (I/O `0x2E/0x2F`) is left enabled: the BIOS finds it and
  routes COM1 to the VUART. (`SCU510[3]` would disable it, but only a power-on
  reset clears that bit and the BIOS may then not use COM1 at all.)
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
