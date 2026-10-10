FILESEXTRAPATHS:prepend:ceb-gnrd := "${THISDIR}/${PN}:"

# IPMI SOL configuration object (/xyz/openbmc_project/ipmi/sol/eth0, interface
# xyz.openbmc_project.Ipmi.SOL).  meta-phosphor does not create it by default, and
# without it phosphor-host-ipmid answers "ipmitool sol info" with "Invalid data
# field" ("Get Sol Config - Invalid solInterface").  Same override as the other
# OpenBMC platforms that offer IPMI SOL.
SRC_URI:append:ceb-gnrd = " file://settings.override.yml"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:ceb-gnrd = " file://0001-ceb-gnrd-bound-persistent-setting-text.patch"
