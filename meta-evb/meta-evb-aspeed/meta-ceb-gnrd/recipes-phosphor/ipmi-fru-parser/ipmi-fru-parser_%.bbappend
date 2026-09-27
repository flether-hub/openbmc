# Enable IPMI FRU (Field Replaceable Unit) parsing for platform inventory
# This provides:
# - Automatic FRU EEPROM detection and parsing
# - Board info, product info, and multirecord areas
# - D-Bus inventory objects creation

MACHINE_FEATURES:append = " ipmi-fru"
