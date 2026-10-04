# CEB-GNRD (inserted by obmc-phosphor-initfs.bbappend): a BMC firmware update does
# not rewrite U-Boot.  The update package carries image-u-boot, but a power loss
# while the U-Boot partition is being written leaves a board that no longer boots
# (recovery only with a flash programmer).  The U-Boot environment is never part
# of the package.  To update U-Boot on purpose, create the file
# /run/initramfs/update-u-boot before the BMC reboots that applies the update.
if test -e "${image}u-boot" -a ! -e /run/initramfs/update-u-boot
then
	echo "Skipping image-u-boot: U-Boot is not rewritten by a BMC update."
	rm -f "${image}u-boot"
fi

# The full flash image (image-bmc, from *.static.mtd.all.tar) covers the whole chip:
# U-Boot, the U-Boot environment with the MAC addresses, and the settings in rwfs.
# Skip it as well unless the same file exists; use *.static.mtd.tar for updates.
if test -e "${image}bmc" -a ! -e /run/initramfs/update-u-boot
then
	echo "Skipping image-bmc: the full flash image would rewrite U-Boot, its"
	echo "environment (MAC addresses) and all settings; use the .static.mtd.tar package."
	rm -f "${image}bmc"
fi
