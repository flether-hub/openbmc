/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * CEB-GNRD: extra default environment variables.
 *
 * CEB_GNRD_ENV is concatenated into CONFIG_EXTRA_ENV_SETTINGS by
 * 0001-ceb-gnrd-board-device-tree-network-and-environment.patch.
 *
 * ethaddr / eth1addr have no compiled board defaults and are not filled by
 * board_late_init. Provision unique MACs in the saved environment as needed.
 * Legacy factory ipaddr/gatewayip/serverip on 192.168.0.x are migrated to
 * the compiled board defaults; custom network addresses remain unchanged.
 *
 * bootnet: load the kernel FIT via TFTP; its initramfs fetches image-rofs
 * from the same server and mounts it with a fresh RAM write overlay.
 * Usage: run bootnet. Default bootcmd remains run bootspi. No Flash writes.
 * Network rootfs download failure stops boot instead of using the old rofs.
 * Use an unused board ipaddr on 192.168.185.0/24 before running bootnet.
 * bootnet uses standard ipaddr/serverip/gatewayip/netmask directly.
 * Missing bootnet variables are also added to an existing saved environment.
 * The old factory bootnet command is migrated and duplicate server/gateway
 * aliases removed; custom scripts and their aliases remain unchanged.
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
#define CEB_GNRD_NETBOOT_KERNEL "image-kernel"
#define CEB_GNRD_NETBOOT_ROFS "image-rofs"
#define CEB_GNRD_NETBOOT_ADDR "0x90000000"
#define CEB_GNRD_BOOTNET \
	"if tftpboot ${netboot_addr} ${netboot_kernel}; then " \
	"if setenv ceb_netboot_saved_bootargs \"${bootargs}\" && " \
	"setenv bootargs \"${bootargs} " \
	"ip=${ipaddr}::${gatewayip}:${netmask}::eth0:off " \
	"ceb-gnrd-netboot=tftp://${serverip}/${netboot_rofs}\"; then " \
	"bootm ${netboot_addr}; " \
	"setenv bootargs \"${ceb_netboot_saved_bootargs}\"; " \
	"setenv ceb_netboot_saved_bootargs; fi; fi"

#define CEB_GNRD_ENV	\
	"netboot_kernel=" CEB_GNRD_NETBOOT_KERNEL "\0" \
	"netboot_rofs=" CEB_GNRD_NETBOOT_ROFS "\0" \
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
