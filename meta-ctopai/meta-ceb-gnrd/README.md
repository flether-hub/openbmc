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
* **phosphor-host-postd + phosphor-post-code-manager**: BIOS POST codes
  (I/O port 0x80) snooped over eSPI/LPC (`CONFIG_ASPEED_LPC_SNOOP`) and
  recorded as boot progress on D-Bus.
* **phosphor-software-manager** with `flash_bios`: host BIOS update via
  flashrom over MTD, with ME/SPS recovery flow via IPMB. See
  `recipes-phosphor/flash/phosphor-software-manager/bios-update.sh` —
  **hardware-specific values (IPMB bus, MTD device, GPIO name) are marked
  with TODO and must be verified against your hardware**.
* **phosphor-ipmi-flash**: IPMI in-band firmware update via BLOB protocol
  (host-bios targets enabled when `flash_bios` PACKAGECONFIG is active).
* **Host/chassis state management**: `MACHINE_FEATURES` includes
  `obmc-host-state-mgmt`, `obmc-chassis-state-mgmt`,
  `obmc-phosphor-chassis-mgmt`, `obmc-phosphor-flash-mgmt` — enables full
  host power control required for BIOS update flows. Machine uses
  `obmc-bsp-common.inc` (managed server), not `obmc-evb-common.inc`.

### eSPI

* `CONFIG_ASPEED_ESPI=y` in `recipes-kernel/linux/files/espi-peci.cfg` —
  the AST2600 eSPI slave connects to the Intel Xeon host's eSPI master.
* Corrected from the original invalid `CONFIG_ASPEED_LPC_ESPI` symbol
  (verified against meta-ibm/meta-system1 reference for linux-aspeed 6.18).

### PECI

* Full PECI client set in `espi-peci.cfg`:
  `CONFIG_PECI`, `CONFIG_PECI_CPU`, `CONFIG_PECI_ASPEED`,
  `CONFIG_SENSORS_PECI_CPUTEMP`, `CONFIG_SENSORS_PECI_DIMMTEMP`.
* `VIRTUAL-RUNTIME_obmc-sensors-hwmon = "dbus-sensors"` in machine conf —
  switches sensor runtime to dbus-sensors, which provides
  **IntelCPUSensor** (PECI-based CPU/DIMM temperature monitoring via
  libpeci). This mirrors the sbp1 configuration.
* Symbols aligned with both meta-asrock and meta-ibm/meta-system1 references
  for the linux-aspeed 6.18 kernel.

### VGA display output

* The AST2600 VGA engine is enabled upstream (`CONFIG_DRM_ASPEED_GFX`,
  `CONFIG_VIDEO_ASPEED` in the aspeed-g6 defconfig) and the image includes
  `obmc-ikvm` (KVM over IP video capture) plus the bmcweb KVM endpoint.

### FRU EEPROM access

* **fru-device** (from entity-manager): probes I2C for FRU EEPROMs and
  publishes their contents on D-Bus (`xyz.openbmc_project.FruDevice`).
* **phosphor-ipmi-fru** (IPMI Get/Read/Write FRU commands): wired to the
  motherboard EEPROM via `obmc-read-eeprom@.service`.
* **Board-specific FRU YAML config** (`ceb-gnrd-yaml-config.bb`): provides
  `ipmi-fru-read.yaml` (FRU section → D-Bus inventory mapping) and
  `ipmi-extra-properties.yaml` (extra properties). Wired into
  phosphor-ipmi-fru via `IPMI_FRU_YAML` / `IPMI_FRU_PROP_YAML`.
  Mirrors the sbp1-yaml-config pattern.
* EEPROM env file at
  `recipes-phosphor/ipmi/phosphor-ipmi-fru/obmc/eeproms/system/chassis/motherboard`
  — **verify the I2C bus/address (`SYSFS_PATH`) against your hardware**.

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

* **Board device tree**: currently reuses `aspeed-ast2600-evb.dtb`. A
  board-specific device tree should be added with:
  - eSPI channel wiring (slave/master configuration)
  - FRU EEPROM node (compatible, reg, bus assignment)
  - BIOS update GPIO definitions
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
