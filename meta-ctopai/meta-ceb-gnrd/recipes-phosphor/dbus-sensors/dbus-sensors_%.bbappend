# Enable sensor support for ceb-gnrd Intel platform
# This configuration extends dbus-sensors to support:
# - PECI CPU/DIMM temperatures
# - PSU sensors via PMBus
# - IPMI sensors

MACHINE_FEATURES:append = " peci-hwmon"
DISTRO_FEATURES:append = " intel-peci"
