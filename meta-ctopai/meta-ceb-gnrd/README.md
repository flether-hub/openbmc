Ceb-gnrd (Intel Xeon 6, AST2600) OpenBMC board layer
================

This layer is nested under the top-level [meta-ctopai](../) vendor layer and
provides the machine definition and build templates for the ceb-gnrd board:
an ASPEED AST2600 BMC managing an Intel Xeon 6 (Granite Rapids) host.

Reference implementation: **meta-ibm/meta-sbp1** (Intel server platform).

Build usage:

    ./setup ceb-gnrd
    bitbake obmc-phosphor-image

Platform features
-----------------

### BIOS interaction (BIOS 菜单交互)

* **PLDM over MCTP** (`conf/distro/include/pldm.inc`): BIOS attribute tables
  and setup (menu) settings exposed through Redfish `Systems/system/Bios`,
  plus PLDM sensors and PLDM firmware update.
* **biosconfig-manager**: view and modify BIOS setup parameters remotely via
  the BMC (see https://github.com/openbmc/bios-settings-mgr).
* **phosphor-host-postd + phosphor-post-code-manager**: intended BIOS POST
  code pipeline for I/O port 0x80. The AST2600 LPC snoop node is enabled for
  port 0x80; validate POST capture on hardware. LPC snoop is only a monitor,
  not the eSPI Peripheral I/O-cycle completion path.
* **phosphor-software-manager** with `flash_bios`: host BIOS update through
  the Macronix MX25U51245GMI00 (64 MiB) on AST2600 SPI1 in single-bit mode.
  The updater refuses to start unless the host is already confirmed off,
  selects BMC flash ownership with GPIOM1/NDCD1 as GPIO before locating the
  MTD (and retries SPI-NOR probe if needed), waits five seconds, flashes the
  full-chip `host-bios` MTD, restores BIOS ownership, requests chassis power-off, then
  requests power-on through the OpenBMC power state manager (the normal host
  Power button path). Confirm GPIO polarity and verify full power removal on
  the assembled board. The BMC's own W25Q512JVFIQ (64 MiB) is on AST2600
  Firmware SPI/FMC and retains the OpenBMC flash partition layout.
* **phosphor-ipmi-flash**: IPMI in-band firmware update via BLOB protocol
  (host-bios targets enabled when `flash_bios` PACKAGECONFIG is active).
* **Host/chassis state management**: `MACHINE_FEATURES` includes
  `obmc-host-state-mgmt`, `obmc-chassis-state-mgmt`,
  `obmc-phosphor-chassis-mgmt`, `obmc-phosphor-flash-mgmt` — enables full
  host power control required for BIOS update flows. Machine uses
  `obmc-bsp-common.inc` (managed server), not `obmc-evb-common.inc`.

### eSPI

* The board wires AST2600 eSPI to the Xeon 6 host. Host KCS/IPMI queries
  require a working eSPI Peripheral-channel controller driver and matching
  device-tree node. GPIOW0-W7 are dedicated to this CPU eSPI connection:
  `pinctrl_espi_default` covers W0-W5/W7 and the separate
  `pinctrl_espialt_default` covers W6/AD7; both are selected by the eSPI node.
  This board does not use Virtual Wire or Flash Access.
  OOB is not required for KCS/IPMI, POST-code, or UART3 SOL; enable it only if
  host MCTP/SMBus is confirmed to tunnel over eSPI OOB.
* The pinned `linux-aspeed` revision (`c0538446`) lacks the AST2600 eSPI
  controller driver and SoC eSPI node. The board now carries a focused driver
  backport and enables `CONFIG_ASPEED_ESPI`; it sets Peripheral Software Ready
  and restores it after host eSPI reset. The eSPI node enables only the
  Peripheral channel. `CONFIG_ASPEED_LPC_SIO` does not exist in this pinned
  kernel and is intentionally not added as a phantom Kconfig option.
* AST2600 handles Peripheral I/O cycles (`PUT_IOWR_SHORT` / `PUT_IORD_SHORT`)
  through its eSPI hardware path to the integrated LPC-compatible I/O blocks;
  they are not software FIFO packets for the generic Peripheral misc-device
  driver to parse. The previous claim that the Aspeed implementation had no
  I/O-cycle support was incorrect. The missing piece in this board was an
  enabled controller setting Peripheral Ready. Port 0x80 snooping is separate
  from cycle completion and remains provided only by `ASPEED_LPC_SNOOP`.
* The full `AspeedTech-BMC/linux` branch driver initializes additional channel
  support and is not copied wholesale. This board-local driver leaves Virtual
  Wire, OOB and Flash channel setup disabled, consistent with the host design.
* Intel-BMC's public OpenBMC tree has eSPI cleanup/U-Boot support patches, but
  no replacement Linux AST2600 eSPI controller driver in the inspected
  recipe paths. Use its platform configuration as reference, not as the
  controller implementation.
* Borrowed from IBM `meta-system1`: enable the ASPEED KCS BMC, IPMI and raw
  cdev options, select `phosphor-ipmi-kcs`, and enable AST2600 `kcs3`, matching
  the service's default `ipmi-kcs3` device. This provides the KCS endpoint,
  not the missing eSPI channel transport; validate KCS I/O decode against the
  Xeon BIOS configuration.
* `CONFIG_ASPEED_LPC_SNOOP` plus the enabled `lpc_snoop` DT node captures
  writes to port 0x80. It does not complete host I/O cycles; AST2600 handles
  LPC-style I/O cycles in hardware after Peripheral Software Ready is asserted.
  Do not add `CONFIG_ASPEED_LPC_SIO`: it is not present in this kernel tree.
* GPIOP7 (`BMC_HBLED#`) starts off. A board service enables the kernel LED
  heartbeat trigger once the AST2600 eSPI Peripheral driver binds and sets
  `SW_READY`. This reports eSPI initialization without waiting for host traffic
  or claiming that a transaction has been observed; verify pulse polarity on
  the assembled board.

### PECI

* AST2600 PECI0 is enabled for the BMC_CPU_PECI connection at package ball
  AT29. The board Entity Manager configuration declares the single Xeon 6
  CPU (PECI bus 0, address 0x30), and the kernel/client stack enables:
  `CONFIG_PECI`, `CONFIG_PECI_CPU`, `CONFIG_PECI_ASPEED`,
  `CONFIG_SENSORS_PECI_CPUTEMP`, `CONFIG_SENSORS_PECI_DIMMTEMP`.
* `VIRTUAL-RUNTIME_obmc-sensors-hwmon = "dbus-sensors"` in machine conf —
  selects dbus-sensors IntelCPUSensor for PECI thermal data. Only AST2600
  I3C3 is enabled for CPU management; I3C1, I3C2 and I3C4 are disabled. DIMM
  temperature is read only from PECI DIMM channels, not I3C. The DIMM sensor
  contract is one maximum reading across present DIMMs; upstream
  IntelCPUSensor currently emits per-DIMM readings, so aggregation remains
  required before that single maximum sensor is fully implemented.
* Symbols aligned with both meta-asrock and meta-ibm/meta-system1 references
  for the linux-aspeed 6.18 kernel.

### RTC and log time

* The NCT3015Y-R is connected to AST2600 I2C10 on its second I2C port
  (`BMC_RTC_I2C10`, Linux `i2c-9`, address `0x6f`); its first port is wired
  to the host CPU RTC bus. The kernel NCT3018Y-compatible driver supports
  this NCT3015Y-R topology and registers it as `rtc0`.
* `CONFIG_RTC_HCTOSYS` initializes BMC system time from the battery-backed
  RTC during boot. `CONFIG_RTC_SYSTOHC` periodically writes synchronized
  system time back to the RTC after userspace reports NTP synchronization.
  SEL and journal timestamps therefore follow the BMC system clock; keep
  the RTC/system timezone in UTC.

### Board hardware map

The workbook-derived map is installed as
`/usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml`. It records the 16
I2C buses, the enabled CPU I3C3 management bus and disabled I3C buses, AST2600 ADC0 channels 0-15, six PWM /
TACH fan channels, and the named power, reset and alert GPIOs. Chassis-open
detection uses the AST2600 dedicated CHASI# intrusion input on package ball
AB21 through the intrusion hwmon latch; it is not a GPIO line. The
dbus-sensors intrusion service publishes the chassis intrusion status and
records assert/reset events in the system journal and Redfish event log. The
board carries a backport of the AST2600 chassis hwmon driver and SoC node;
`CONFIG_SENSORS_ASPEED_CHASSIS=y` plus the board's enabled `&chassis` node
expose the latch as `intrusion0_alarm` for dbus-sensors. Verify open/close
detection and event logging on the target board.
The board's schematic I2C7 (Linux `i2c-6`) reads four NST175H-QSPR sensors:
inlet U30 at `0x48`, outlet U33 at `0x49`, PCIe U32 at `0x4a`, and M.2 U31
at `0x4b`. They are measurement-only temperature sensors with no threshold
alarm configuration. The kernel fragment also enables AST2600 ADC, I3C,
PMBus and G6 PWM/TACH support. Signal-table GPIOs are mapped to AST2600 banks
and Linux offsets in the device tree and hardware contract; unknown electrical
polarities and vendor-specific PMBus mappings remain marked pending.

The CRPS interface is schematic I2C8 (AST2600 I2C8, Linux `i2c-7`) using the
generic Linux PMBus driver. Addresses `0x58`, `0x59` and `0x5a` are configured
as optional modules. Entity Manager/PSUSensor publishes each detected module's
input voltage, output voltage, input power and output power as independent
standard sensors. No PSU-presence, redundancy-count or threshold alarm is
configured, so a system populated with fewer than three modules does not
create missing-module alarms.

The CPU PROM/SMBUS_HOST connection uses BMC nets `BMC_PROM_SCL/SDA` on AST2600
I2C15, muxed to GPIOH4/SCL15 and GPIOH5/SDA15 (Linux `/dev/i2c-14`). Its
remote EEPROM address and exact part number are not present in the supplied
schematic excerpt, so the bus is enabled but no guessed EEPROM client is
created.

### BMC network ports

The product exposes two BMC network paths:

* `eth0`: MAC2 with RTL8211FS-CG on the independent management RJ45. It boots
  with static IPv4 `192.168.1.200/24`, gateway and DNS `192.168.1.1`.
* `eth1`: MAC3 NC-SI connection to the Intel E810, also represented as IPMI
  LAN channel 2.

The Linux and U-Boot device trees enforce this mapping: Linux/U-Boot phandle
`mac1` is physical AST2600 MAC2 (1.8 V RGMII2 / RTL8211FS-CG), paired with the
`mdio1` bus / `ethphy1`; phandle `mac2` is physical MAC3 (NCSI3 / Intel E810).
Physical MAC1 and MAC4 are disabled, as is the unused PHY-management bus for
physical MAC3. Linux uses the AST2600 NCSI3 pin group. After
flashing the updated image, only these two network devices should be
available. An old image may continue to expose the EVB's four MACs until its
device trees are replaced.

The Web UI fan-control page uses the bmcweb OpenBMC fan-controller Redfish
API. It provides adaptive mode with a configurable 10-100% minimum PWM limit,
or fixed 20/40/60/80/100% presets, for all fans together or one controller at
a time. At power-on the CPLD owns fan control. The BMC fan-owner service waits
for `phosphor-fan-control@0.service`, a configured FanCtrl zone on D-Bus, and
all six writable PWM/readable TACH channels before asserting high on
GPIOI6/PBI# to connect the BMC PWM outputs to the fans. If the fan-control
service stops, the owner service deasserts PBI# so the CPLD regains control. If
readiness checks fail, the BMC leaves control with the CPLD. A production
thermal profile is still required for closed-loop adaptive control; without a
configured FanCtrl zone, BMC ownership is not asserted. Installed fan count is
not fixed: zero or abnormal tach readings are telemetry only and do not create
logs, presence changes, or alarms.
Adaptive PID controller objects still need to be supplied by the board's
production thermal profile. Until those objects are present on D-Bus, the
WebUI reports fan control as unavailable rather than suggesting the settings
are active.

### Web UI languages

The CEB-GNRD Web UI language picker is restricted to English (`en-US`) and
Simplified Chinese (`zh-CN`). Other upstream translation files remain
available to the generic WebUI recipe but are filtered out for this machine,
including stale saved language selections.

### VGA display output

* AST2600 GFX DAC output is enabled to provide the CPU's VGA display path:
  `CONFIG_DRM_ASPEED_GFX` and `&gfx` are enabled, with GPIOL6/VGAHS and
  GPIOL7/VGAVS selected in the board DTS. The schematic maps DAC B/G/R to
  AD21/AE21/AF21, sync to B14/C14, and DDC clock/data to B8/A8.
* VGA DDC pins are fixed-function signals in the pinned AST2600 pinctrl and
  have no separate pinctrl groups; no extra mux selection is required. The
  separate `CONFIG_VIDEO_ASPEED` / `&video` path captures host video for KVM;
  it is not the GFX DAC output path. The image includes `obmc-ikvm` and bmcweb
  KVM endpoint.

### KVM USB connection

* AST2600 USB2A D+/D- connects to host VL805 USB port 4. The board DTS enables
  the AST2600 vHub in USB2A device mode (`pinctrl_usb2ad_default`) and disables
  EHCI host mode on that same port. Kernel support for the vHub and configfs
  HID is enabled in the aspeed-g6 defconfig; KVM uses the video capture path
  together with the virtual USB keyboard/mouse path.

### Host serial-over-LAN

* CPU serial TX/RX is wired to AST2600 UART3 (`GPIOL4/TXD3` and
  `GPIOL5/RXD3`). UART3 is enabled in the board DTS and `obmc-console` uses
  `ttyS2` as its host console for SOL access.
* UART5 (`ttyS4`, 115200 baud) is the local BMC debug console and is explicitly
  enabled in the board DTS. The schematic routes AST2600 TXD5/RXD5 to
  `BMC_UART5_DEBUG_TXD/RXD` on package balls C8/D8. U-Boot sets `stdout-path`
  to UART5 and retains it in SPL with `bootph-all`; Linux `SERIAL_CONSOLES`
  maps `ttyS4` at 115200 baud. UART3 (`ttyS2`) remains reserved for host SOL.
  UART5 has no separate pinctrl group in the pinned AST2600 pinctrl driver;
  verify boot logs on the physical debug header.

### FRU EEPROM access

* **fru-device** (from entity-manager): probes I2C for FRU EEPROMs and
  publishes their contents on D-Bus (`xyz.openbmc_project.FruDevice`).
* **phosphor-ipmi-fru** (IPMI Get/Read/Write FRU commands): wired to the
  FM24C08D motherboard EEPROM on schematic I2C11 (Linux `i2c-10`),
  address blocks `0x50`-`0x53`, via `obmc-read-eeprom@.service`. It is 8 Kbit
  (1 KiB) with 16-byte pages; its 24C02 package outline does not indicate capacity.
* **Board-specific FRU YAML config** (`ceb-gnrd-yaml-config.bb`): provides
  `ipmi-fru-read.yaml` (FRU section → D-Bus inventory mapping) and
  `ipmi-extra-properties.yaml` (extra properties). Wired into
  phosphor-ipmi-fru via `IPMI_FRU_YAML` / `IPMI_FRU_PROP_YAML`.
  Mirrors the sbp1-yaml-config pattern.
* EEPROM env file at
  `recipes-phosphor/ipmi/phosphor-ipmi-fru/obmc/eeproms/system/chassis/motherboard`
  points to `/sys/bus/i2c/devices/10-0050/eeprom`. The schematic connects
  EEPROM WP to `BMC_FRU_WP` and shows a 4.7-kOhm pulldown, so writes are
  enabled by default. The AST2600 GPIO/ball mapping is not shown in the
  supplied pin table; firmware-side toggling of write protection is not
  configured.

Notes / TODO
------------

### Hardware interface contract

The image installs the data-only `ceb-gnrd-hardware-contract` package. Its
YAML file records the names, units, sources and pending board mappings for the
requested temperature, voltage, PMBus, fan, event, FRU and management
interfaces. It does not publish synthetic readings or enable unverified GPIO
and I2C addresses, so the EVB-based image remains safe to boot before the
production schematic is available.

The current machine configuration already selects the common OpenBMC services
for PECI/dbus-sensors, host/chassis state, PLDM/MCTP, FRU, console, KVM,
firmware update and watchdog. Virtual media remains provider-layer-specific
until the target OpenBMC branch supplies the corresponding component.
Hardware-specific work should replace the
`pending-*` entries in the contract with Entity-Manager/dbus-sensors, PMBus,
GPIO and device-tree mappings. The contract file is installed at
`/usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml`.

* **Board device tree**: the machine now uses a board-specific device tree
  derived from the AST2600 EVB with:
  - eSPI channel wiring (slave/master configuration)
  - FRU EEPROM node (compatible, reg, bus assignment)
  - BIOS MX25U51245GMI00 on SPI1 CS0 (single-bit, Linux BIOS-update only) and
    BMC W25Q512JVFIQ on Firmware SPI/FMC with explicit `FWSPID` + `FWQSPI`
    pinmux in Linux and U-Boot for x4 operation; GPIOM1/NDCD1 selects BIOS-flash ownership
  - Host UART routing
* **BIOS version reporting**: sbp1's `bios-version` recipe extracts
  COREBOOT_VERSION strings (coreboot-specific). For UEFI-based Xeon 6
  platforms, a different extraction method is needed (e.g., SMBIOS Type 0,
  or vendor-specific flash markers). Not yet implemented.
* **Entity-manager JSON configs**: can be added later for detailed inventory
  exposure (sensor associations, connector mappings, etc.). fru-device
  auto-probes EEPROMs without them.

The AST2600 is an ARM, service management SOC made by ASPEED. More information
about the AST2600 can be found
[here](http://aspeedtech.com/server_ast2600/).
# Board revision in IPMI

The three `PCB_VER[2:0]` strap inputs are sampled as GPIO inputs. Their raw
logic levels encode the board revision as `(PCB_VER2 << 2) | (PCB_VER1 << 1) |
PCB_VER0`, producing a value from 0 to 7. `ipmitool mc info` reports this value
in the fourth (last) byte of the AUX Firmware Revision field. The first three
AUX bytes remain unchanged. `CFG_VER0` is a separate configuration strap and
is not included in the PCB revision.
