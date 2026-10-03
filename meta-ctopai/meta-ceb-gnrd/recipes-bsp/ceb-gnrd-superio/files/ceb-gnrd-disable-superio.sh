#!/bin/sh
# Disable the AST2600 built-in SuperIO so that the host BIOS no longer finds a
# "BMC SuperIO" at I/O 0x2E/0x2F.  With it present, the BIOS enables COM1 (0x3F8)
# on eSPI through the SuperIO SUART1 and polls the line status register 0x3FD
# forever; this board has no VUART path (the host serial goes to the physical
# UART3), so that register never reports "transmitter empty" and the BIOS hangs.
#
# AST2600 datasheet: SCU510[3] "Disable LPC to decode SuperIO 0x2E/0x4E address"
# (RW1S: written with 1 it sets the bit, other bits are untouched; it is only
# cleared by a power-on reset, so it is set again on every BMC boot).  KCS, the
# port 0x80 snoop and the eSPI Peripheral channel itself are not affected.
SCU_KEY=0x1e6e2000
SCU_STRAP2=0x1e6e2510
BIT3=0x8

key_was_locked=0
if [ "$(devmem $SCU_KEY 32)" = "0x00000000" ]; then
    # SCU is write protected: unlock for this one write and lock it again.
    key_was_locked=1
    devmem $SCU_KEY 32 0x1688A8A8
fi

devmem $SCU_STRAP2 32 $BIT3

if [ "$key_was_locked" = 1 ]; then
    devmem $SCU_KEY 32 0
fi

value=$(devmem $SCU_STRAP2 32)
if [ $(( value & BIT3 )) -eq 0 ]; then
    echo "ceb-gnrd-disable-superio: SCU510[3] did not stick (SCU510=$value)" >&2
    exit 1
fi
echo "ceb-gnrd-disable-superio: SuperIO decode disabled (SCU510=$value)"