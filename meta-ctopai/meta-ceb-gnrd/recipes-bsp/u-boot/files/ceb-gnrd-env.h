/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * CEB-GNRD: extra default environment variables.
 *
 * CEB_GNRD_ENV is concatenated into CONFIG_EXTRA_ENV_SETTINGS (see the sed in
 * u-boot-aspeed-sdk_%.bbappend).
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
#define CEB_GNRD_ENV	\
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
