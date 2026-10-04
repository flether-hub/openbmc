inherit obmc-phosphor-systemd

FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

# IPMI Write FRU Data ("ipmitool fru write") also writes the FRU EEPROM, not
# only the inventory (IPMI spec: it writes the FRU storage).
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-write-fru-data-to-eeprom.patch"

# Board-specific FRU YAML configuration provider (mirrors sbp1-yaml-config).
DEPENDS:append:ceb-gnrd = " ceb-gnrd-yaml-config"

IPMI_FRU_YAML:ceb-gnrd = "${STAGING_DIR_HOST}${datadir}/ceb-gnrd-yaml-config/ipmi-fru-read.yaml"
IPMI_FRU_PROP_YAML:ceb-gnrd = "${STAGING_DIR_HOST}${datadir}/ceb-gnrd-yaml-config/ipmi-extra-properties.yaml"

# ceb-gnrd motherboard FRU EEPROM: instantiates obmc-read-eeprom@.service
# for the "system/chassis/motherboard" EEPROM, which reads the FRU data
# into the inventory item backed by phosphor-ipmi-fru.
EEPROM_NAMES = "motherboard"

EEPROMFMT = "system/chassis/{0}"
EEPROM_ESCAPEDFMT = "system-chassis-{0}"
EEPROMS = "${@compose_list(d, 'EEPROMFMT', 'EEPROM_NAMES')}"
EEPROMS_ESCAPED = "${@compose_list(d, 'EEPROM_ESCAPEDFMT', 'EEPROM_NAMES')}"

ENVFMT = "obmc/eeproms/{0}"
SYSTEMD_ENVIRONMENT_FILE:${PN}:append:ceb-gnrd := " ${@compose_list(d, 'ENVFMT', 'EEPROMS')}"

TMPL = "obmc-read-eeprom@.service"
TGT = "${SYSTEMD_DEFAULT_TARGET}"
INSTFMT = "obmc-read-eeprom@{0}.service"
FMT = "../${TMPL}:${TGT}.wants/${INSTFMT}"

SYSTEMD_LINK:${PN}:append:ceb-gnrd := " ${@compose_list(d, 'FMT', 'EEPROMS_ESCAPED')}"
