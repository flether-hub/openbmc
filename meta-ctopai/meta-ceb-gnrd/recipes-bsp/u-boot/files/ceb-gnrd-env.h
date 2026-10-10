/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * CEB-GNRD: extra default environment variables.
 *
 * CEB_GNRD_ENV is concatenated into CONFIG_EXTRA_ENV_SETTINGS by
 * 0001-ceb-gnrd-board-device-tree-network-and-environment.patch.
 *
 * ethaddr / eth1addr: stable locally administered bring-up defaults for
 * ethernet0 (MAC2/RGMII) and ethernet1 (MAC3/NC-SI). Provision unique MACs
 * per physical board or concurrent simulator instance in the saved
 * environment. A valid saved environment takes precedence over defaults;
 * board_late_init fills missing MAC variables in an existing environment and
 * saves the migration once. Existing nonempty variables are preserved.
 * Legacy factory ipaddr/gatewayip/serverip on 192.168.0.x are migrated to
 * the compiled board defaults; custom network addresses remain unchanged.
 *
 * bootnet: load the kernel FIT via TFTP into RAM and boot it without flashing.
 * Usage: run bootnet. Default bootcmd remains run bootspi. The FIT initramfs
 * still mounts rofs/rwfs from SPI; this is not a diskless root filesystem.
 * Use an unused board ipaddr on 192.168.185.0/24 before running bootnet.
 * Missing bootnet variables are also added to an existing saved environment.
 *
 * netupdate: fetch the kernel FIT and the read-only root filesystem from the
 * TFTP server and write them to the SPI flash.  U-Boot itself, its environment
 * (0x000000-0x0fffff) and the read-write partition (rwfs, 0x3200000) are left
 * alone.  Partition layout (must match the device trees):
 *   kernel  0x0100000  size 0x0900000
 *   rofs    0x0a00000  size 0x2800000
 * ${filesize} is a hex string without "0x", hence "0x${filesize}" for test.
 * Usage:  run netupdate      (then: reset)
 * The files are taken from ${serverip}; names are in netupdate_kernel and
 * netupdate_rofs.
 */
#define CEB_GNRD_DEFAULT_MAC0 "02:26:00:00:00:01"
#define CEB_GNRD_DEFAULT_MAC1 "02:26:00:00:00:02"
#define CEB_GNRD_NETBOOT_SERVER "192.168.185.84"
#define CEB_GNRD_NETBOOT_GATEWAY "192.168.185.1"
#define CEB_GNRD_NETBOOT_KERNEL "image-kernel"
#define CEB_GNRD_NETBOOT_ADDR "0x90000000"
#define CEB_GNRD_BOOTNET \
	"setenv serverip ${netboot_server} && " \
	"setenv gatewayip ${netboot_gateway} && " \
	"tftpboot ${netboot_addr} ${netboot_kernel} && " \
	"bootm ${netboot_addr}"

#define CEB_GNRD_ENV	\
	"ethaddr=" CEB_GNRD_DEFAULT_MAC0 "\0"	\
	"eth1addr=" CEB_GNRD_DEFAULT_MAC1 "\0"	\
	"netboot_server=" CEB_GNRD_NETBOOT_SERVER "\0" \
	"netboot_gateway=" CEB_GNRD_NETBOOT_GATEWAY "\0" \
	"netboot_kernel=" CEB_GNRD_NETBOOT_KERNEL "\0" \
	"netboot_addr=" CEB_GNRD_NETBOOT_ADDR "\0" \
	"bootnet=" CEB_GNRD_BOOTNET "\0" \
	"netupdate_kernel=image-kernel\0"	\
	"netupdate_rofs=image-rofs\0"	\
	"netupdate="	\
		"sf probe 0 && "	\
		"tftpboot 0x90000000 ${netupdate_kernel} && "	\
		"test 0x${filesize} -le 0x900000 && "	\
		"sf update 0x90000000 0x100000 ${filesize} && "	\
		"tftpboot 0x90000000 ${netupdate_rofs} && "	\
		"test 0x${filesize} -le 0x2800000 && "	\
		"sf update 0x90000000 0xa00000 ${filesize} && "	\
		"echo Network update done, run reset || "	\
		"echo Network update FAILED"	\
	"\0"
