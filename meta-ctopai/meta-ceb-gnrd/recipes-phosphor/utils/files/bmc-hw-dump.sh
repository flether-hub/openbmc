#!/bin/sh
# bmc-hw-dump.sh - read-only dump of how a running AST2600 BMC firmware uses the
# board hardware, so the vendor firmware and the new ceb-gnrd firmware can be
# compared before the new image is deployed.
#
# Usage
#   On the BMC (old vendor firmware first, later the new firmware):
#     sh bmc-hw-dump.sh            dump into /tmp/bmc-hw-<host>-<time>.tar.gz
#     sh bmc-hw-dump.sh -s         also scan the I2C buses (i2cdetect -r, see below)
#     sh bmc-hw-dump.sh -n         do not read the known ceb-gnrd chips over I2C
#     sh bmc-hw-dump.sh -R         skip direct MMIO register reads
#     sh bmc-hw-dump.sh -a         print every text file to the console too (long)
#   The checklist (ceb-gnrd-checklist.txt) is always printed at the end.
#     sh bmc-hw-dump.sh -o DIR     write the dump directory under DIR instead of /tmp
#   On the PC (Linux or Git Bash), after copying both archives off the BMCs:
#     sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz
#
# What it collects
#   device tree (raw blob, enabled nodes, gpio-line-names), GPIO direction/value of
#   every pin (register decode, GPIOA0..GPIOZ7), SCU pin-mux / strap / clock-delay
#   registers, I2C buses and bound devices (+ FRU EEPROM contents), hwmon (ADC,
#   fans, PWM, temperatures, PSU), IIO ADC, eSPI / LPC (KCS, snoop, SuperIO) /
#   VUART configuration registers, UARTs and which process holds them, network
#   (MAC, PHY address, NC-SI, IP), SPI flash partitions, LEDs, watchdog, RTC,
#   USB device, video, PECI, kernel log and process list, ipmitool output,
#   BMC debug console (console=, getty, UART nodes) and VGA / KVM video engine.
#   DDR configuration/training results, PLLs, all bus bindings including
#   unbound devices, USB gadget/HID/NBD configuration and SPI NOR SFDP.
#   port-guide-coverage.txt maps port_guide.xlsx rows to collected evidence.
#   hardware-limits.txt explains information that requires board measurements.
#   ceb-gnrd-checklist.txt lists every hardware function of the ceb-gnrd firmware
#   with the value the new firmware expects next to what this firmware shows.
#   chips.txt lists the external chips (device tree compatibles, I2C / SPI
#   devices and their drivers, flash JEDEC IDs, PHY IDs, PSU models, modules).
#
# Safety
#   Nothing on the BMC is changed: the script only reads files and registers and
#   writes its output under /tmp (or -o DIR).  Registers are read with devmem
#   only from a fixed list of configuration registers; FIFO / data ports that
#   are cleared by a read (UART RBR, KCS IDR/ODR, eSPI channel data ports) are
#   never touched.  Without /dev/mem or devmem the register part is skipped.
#   The optional I2C scan (-s) sends one read-byte transaction to every free
#   address; that is harmless for normal sensors / EEPROMs / PSUs, but it is
#   still bus traffic, so it is off by default.
#   The chip identification (on by default, -n turns it off) reads a few
#   registers of the known ceb-gnrd chips (temperature sensors, RTC, FRU EEPROM,
#   PMBus PSU identity) with single SMBus read transactions; it never writes a
#   register, and works on the vendor firmware even without kernel drivers.

PATH=$PATH:/usr/sbin:/sbin:/usr/bin:/bin

# ---------------------------------------------------------------- compare mode
if [ "${1:-}" = compare ]; then
    if [ $# -ne 3 ]; then
        echo "usage: $0 compare OLD.tar.gz NEW.tar.gz" >&2
        exit 2
    fi
    work=$(mktemp -d 2>/dev/null || echo "/tmp/bmc-hw-compare.$$")
    mkdir -p "$work/old" "$work/new"
    tar -xzf "$2" -C "$work/old" || exit 1
    tar -xzf "$3" -C "$work/new" || exit 1
    old=$(ls -d "$work"/old/*/ | head -n 1)
    new=$(ls -d "$work"/new/*/ | head -n 1)
    echo "old: $2"
    echo "new: $3"
    # Files that describe the hardware usage; live readings (sensor values, logs,
    # uptime) are left out because they always differ.
    for f in \
        gpio-pins.txt gpio-line-names.txt dt-enabled-nodes.txt scu-regs.txt \
        espi-regs.txt lpc-regs.txt vuart-regs.txt \
        i2c-devices.txt i2c-scan.txt hwmon-layout.txt iio-layout.txt \
        serial.txt net-layout.txt mtd.txt leds.txt watchdog.txt rtc.txt \
        dev-nodes.txt console-vga.txt chips.txt ceb-gnrd-checklist.txt \
        memory-config.txt memory-regs.txt clock-config.txt mac-regs.txt gpio18-pins.txt \
        dt-hardware-cells.txt \
        bus-bindings.txt usb-config.txt flash-config.txt board-config.txt \
        port-guide-coverage.txt hardware-limits.txt
    do
        if [ ! -e "$old/$f" ] && [ ! -e "$new/$f" ]; then
            continue
        fi
        echo
        echo "=================================================== $f"
        if diff -u "$old/$f" "$new/$f" > "$work/diff" 2>&1; then
            echo "(same)"
        else
            sed '1,2d' "$work/diff"
        fi
    done
    rm -rf "$work"
    exit 0
fi

# ---------------------------------------------------------------- options
SCAN=0
PROBE=1
ALL=0
REGS=1
OUTBASE=/tmp
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SCAN=1 ;;
        -n) PROBE=0 ;;
        -R) REGS=0 ;;
        -a) ALL=1 ;;
        -o) shift; OUTBASE=${1:?-o needs a directory} ;;
        -h|--help) sed -n '2,/^PATH=/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown option $1 (see -h)" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$OUTBASE" && OUTBASE=$(cd "$OUTBASE" && pwd) || exit 1
HOST=$(hostname 2>/dev/null || echo bmc)
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
NAME=bmc-hw-$HOST-$STAMP-$$
OUT=$OUTBASE/$NAME
mkdir -p "$OUT" || exit 1
LOG=$OUT/00-run.log

say() { echo "$*"; echo "$*" >> "$LOG"; }
have() { command -v "$1" >/dev/null 2>&1; }

# busybox "timeout" is "timeout -t N" on old builds and "timeout N" on new ones.
TMO=""
if have timeout; then
    if timeout 1 true >/dev/null 2>&1; then
        TMO="timeout 20"
    elif timeout -t 1 true >/dev/null 2>&1; then
        TMO="timeout -t 20"
    fi
fi

# run FILE TITLE CMD... : append "$ CMD" and its output (stdout+stderr) to FILE.
run() {
    file=$1; shift
    title=$1; shift
    {
        echo "### $title"
        echo "\$ $*"
        $TMO "$@" 2>&1
        rc=$?
        echo "[exit=$rc; 124/137 may indicate timeout]"
        echo
    } >> "$OUT/$file"
}

# show FILE PATH... : append "path: content" of small sysfs/proc files.
show() {
    file=$1; shift
    for p in "$@"; do
        [ -r "$p" ] || continue
        v=$(tr '\0' ' ' < "$p" 2>/dev/null | cut -c1-2000 | head -n 50)
        echo "$p: $v" >> "$OUT/$file"
    done
}

say "bmc-hw-dump: writing $OUT"

# ---------------------------------------------------------------- 1. system
say "[1/15] system information"
run system.txt "kernel" uname -a
show system.txt /proc/version /proc/cmdline /etc/os-release /etc/version /etc/issue \
    /etc/timestamp /proc/device-tree/model /proc/device-tree/compatible
run system.txt "uptime" uptime
run system.txt "date" date
run system.txt "cpu" cat /proc/cpuinfo
run system.txt "memory" cat /proc/meminfo
run system.txt "mounts" cat /proc/mounts
run system.txt "disk usage" df -h
have fw_printenv && run system.txt "U-Boot environment (read only)" fw_printenv
run processes.txt "processes" ps w
have ps && ps -ef >/dev/null 2>&1 && run processes.txt "processes (full)" ps -ef
have systemctl && run processes.txt "systemd units" systemctl list-units --all --no-pager
have netstat && run processes.txt "listening sockets" netstat -tulnp
run kernel.txt "loaded modules" cat /proc/modules
run kernel.txt "interrupts" cat /proc/interrupts
run kernel.txt "iomem" cat /proc/iomem
run kernel.txt "kernel config (if exposed)" sh -c 'zcat /proc/config.gz 2>/dev/null || echo "no /proc/config.gz"'
run dmesg.txt "kernel log" dmesg
have journalctl && run journal.txt "journal (last 3000 entries this boot)" journalctl -b --no-pager -n 3000
[ -r /var/log/messages ] && run journal.txt "/var/log/messages" tail -n 3000 /var/log/messages

# ---------------------------------------------------------------- 2. device tree
say "[2/15] device tree"
if [ -r /sys/firmware/fdt ]; then
    cp /sys/firmware/fdt "$OUT/device-tree.dtb" 2>/dev/null &&
        echo "raw blob saved: decompile on the PC with  dtc -I dtb -O dts device-tree.dtb" >> "$OUT/system.txt"
fi
if have dtc && [ -d /proc/device-tree ]; then
    run system.txt "complete live device tree (binary properties preserved)" \
        dtc -I fs -O dtb -o "$OUT/device-tree-live.dtb" /proc/device-tree
fi
if [ -d /proc/device-tree ]; then
    # Every node with a status property, sorted, so enabled/disabled blocks can be
    # compared directly ("okay" nodes are what the firmware uses).
    find /proc/device-tree -name status 2>/dev/null | sort | while read -r s; do
        printf '%s %s\n' "$(dirname "$s" | sed 's|^/proc/device-tree||')" \
            "$(tr -d '\0' < "$s")"
    done > "$OUT/dt-enabled-nodes.txt"
    # Whole tree as text (path = value), small properties only.
    find /proc/device-tree -type f 2>/dev/null | sort | while read -r p; do
        sz=$(wc -c < "$p" 2>/dev/null)
        if [ "${sz:-0}" -le 512 ]; then
            v=$(tr '\0' '|' < "$p" | tr -c '[:print:]' '.')
            echo "${p#/proc/device-tree}: $v"
        else
            echo "${p#/proc/device-tree}: <$sz bytes>"
        fi
    done > "$OUT/dt-properties.txt"
fi

# ---------------------------------------------------------------- 3. GPIO
say "[3/15] GPIO"
bank_name() {
    # offset -> GPIO name, AST2600 bank order A..Z, AA, AB ...
    b=$(( $1 / 8 )); p=$(( $1 % 8 ))
    letters=ABCDEFGHIJKLMNOPQRSTUVWXYZ
    if [ "$b" -lt 26 ]; then
        l=$(echo "$letters" | cut -c$((b + 1)))
    else
        l=A$(echo "$letters" | cut -c$((b - 25)))
    fi
    echo "GPIO$l$p"
}
NAMES=$OUT/.gpio0-names
: > "$NAMES"
for g in /proc/device-tree/ahb/apb/gpio@1e780000 $(find /proc/device-tree -maxdepth 4 -name 'gpio@1e780000' 2>/dev/null); do
    if [ -r "$g/gpio-line-names" ]; then
        tr '\0' '\n' < "$g/gpio-line-names" > "$NAMES"
        break
    fi
done
if [ -s "$NAMES" ]; then
    n=0
    while read -r line; do
        [ -n "$line" ] && printf '%-4s %-8s %s\n' "$n" "$(bank_name $n)" "$line"
        n=$((n + 1))
    done < "$NAMES" > "$OUT/gpio-line-names.txt"
else
    echo "no gpio-line-names in the device tree (vendor firmware may use its own GPIO table)" \
        > "$OUT/gpio-line-names.txt"
fi
have gpioinfo && run gpio-kernel.txt "gpioinfo" gpioinfo
have gpiodetect && run gpio-kernel.txt "gpiodetect" gpiodetect
[ -r /sys/kernel/debug/gpio ] && run gpio-kernel.txt "debugfs gpio (requested lines)" cat /sys/kernel/debug/gpio
[ -r /sys/kernel/debug/pinctrl/pinctrl-handles ] && \
    run gpio-kernel.txt "debugfs pinctrl handles" cat /sys/kernel/debug/pinctrl/pinctrl-handles
for d in /sys/kernel/debug/pinctrl/*; do
    [ -r "$d/pinmux-pins" ] && run gpio-kernel.txt "pinmux $d" cat "$d/pinmux-pins"
done
for d in /sys/class/gpio/gpio[0-9]*; do
    [ -d "$d" ] || continue
    echo "$d direction=$(cat "$d/direction" 2>/dev/null) value=$(cat "$d/value" 2>/dev/null) active_low=$(cat "$d/active_low" 2>/dev/null)"
done > "$OUT/gpio-sysfs-exported.txt"

# ---------------------------------------------------------------- register access
DEVMEM=""
if [ "$REGS" = 1 ] && [ -e /dev/mem ] &&
    grep -q 'aspeed,ast2600' /proc/device-tree/compatible 2>/dev/null; then
    if have devmem; then DEVMEM=devmem
    elif have busybox && $TMO busybox devmem 0x1e6e2004 >/dev/null 2>&1; then DEVMEM="busybox devmem"
    fi
fi
rd() {
    # rd ADDR -> 0x%08x value or "--------"
    v=$($TMO $DEVMEM "$(printf '0x%08x' "$1")" 32 2>/dev/null)
    case "$v" in
        0x[0-9a-fA-F]*) printf '0x%08x' "$v" ;;
        *) echo "----------" ;;
    esac
}
dump_range() {
    # dump_range FILE TITLE BASE FIRST LAST : 32-bit registers BASE+FIRST..BASE+LAST
    file=$1 title=$2 base=$3 off=$(($4)) last=$(($5))
    echo "### $title" >> "$OUT/$file"
    while [ "$off" -le "$last" ]; do
        printf '0x%08x %s\n' $((base + off)) "$(rd $((base + off)))" >> "$OUT/$file"
        off=$((off + 4))
    done
    echo >> "$OUT/$file"
}
dump_list() {
    # dump_list FILE TITLE BASE OFF:NAME ...
    file=$1 title=$2 base=$3; shift 3
    echo "### $title" >> "$OUT/$file"
    for e in "$@"; do
        off=${e%%:*}; nm=${e#*:}
        printf '0x%08x %-11s %s\n' $((base + off)) "$(rd $((base + off)))" "$nm" >> "$OUT/$file"
    done
    echo >> "$OUT/$file"
}

if [ -n "$DEVMEM" ]; then
    # ------------------------------------------------------------ 4. SCU
    say "[4/15] SCU (chip id, straps, pin mux, clock delays)"
    {
        echo "SCU004 silicon revision: $(rd 0x1e6e2004)  (AST2600 A3 = 0x05030303)"
        echo "SCU014 silicon revision 2: $(rd 0x1e6e2014)"
        echo "SCU500 hw strap 1: $(rd 0x1e6e2500)   SCU510 hw strap 2: $(rd 0x1e6e2510)"
        echo
    } > "$OUT/scu-regs.txt"
    # The SCU only holds configuration registers, reading them has no effect.
    dump_range scu-regs.txt "SCU 0x000-0x0ff (reset, clock gates)" 0x1e6e2000 0x000 0x0fc
    dump_range scu-regs.txt "SCU 0x300-0x3ff (clock selection, MAC RGMII delays 0x340-0x35c)" 0x1e6e2000 0x300 0x3fc
    dump_range scu-regs.txt "SCU 0x400-0x4ff (multi-function pin control)" 0x1e6e2000 0x400 0x4fc
    dump_range scu-regs.txt "SCU 0x500-0x5ff (hardware straps)" 0x1e6e2000 0x500 0x5fc
    dump_range scu-regs.txt "SCU 0x600-0x6ff (pin control, drive strength, pull-down)" 0x1e6e2000 0x600 0x6fc

    # ------------------------------------------------------------ 5. GPIO registers
    say "[5/15] GPIO controller registers (direction and value of every pin)"
    dump_range gpio-regs.txt "GPIO 3.3V controller 0x1e780000" 0x1e780000 0x000 0x1fc
    dump_range gpio-regs.txt "GPIO 1.8V controller 0x1e780800" 0x1e780800 0x000 0x0fc
    # Decode: data / direction register pairs, 4 banks of 8 pins per register.
    {
        printf '%-8s %-4s %-4s %-5s %s\n' PIN OFFS DIR VALUE LINE-NAME
        for grp in "ABCD 0x000 0x004 0" "EFGH 0x020 0x024 32" "IJKL 0x070 0x074 64" \
                   "MNOP 0x078 0x07c 96" "QRST 0x080 0x084 128" "UVWX 0x088 0x08c 160" \
                   "YZ 0x1e0 0x1e4 192"; do
            set -- $grp
            data=$(rd $((0x1e780000 + $2))); dir=$(rd $((0x1e780000 + $3))); first=$4
            case "$data$dir" in *-*) continue ;; esac
            nbanks=${#1}
            bit=0
            while [ "$bit" -lt $((nbanks * 8)) ]; do
                o=$((first + bit))
                d=$(( (dir >> bit) & 1 )); v=$(( (data >> bit) & 1 ))
                [ "$d" = 1 ] && d=out || d=in
                ln=""
                [ -s "$NAMES" ] && ln=$(sed -n "$((o + 1))p" "$NAMES")
                printf '%-8s %-4s %-4s %-5s %s\n' "$(bank_name $o)" "$o" "$d" "$v" "$ln"
                bit=$((bit + 1))
            done
        done
        echo
        echo "Note: VALUE is the data register (pin level for inputs, driven level for"
        echo "outputs).  A pin whose function is muxed away from GPIO (see scu-regs.txt)"
        echo "shows a meaningless value here."
    } > "$OUT/gpio-pins.txt"
    {
        echo "PIN DIRECTION VALUE (AST2600 36 GPIOs on the 1.8 V controller)"
        for grp in "ABCD 0x000 0x004 0 32" "E 0x020 0x024 32 4"; do
            set -- $grp
            data=$(rd $((0x1e780800 + $2))); dir=$(rd $((0x1e780800 + $3)))
            first=$4 count=$5
            case "$data$dir" in *-*) echo "SKIP: group $1 unreadable"; continue ;; esac
            bit=0
            while [ "$bit" -lt "$count" ]; do
                pin=$(bank_name $((first + bit)))
                d=$(((dir >> bit) & 1)); v=$(((data >> bit) & 1))
                [ "$d" = 1 ] && d=out || d=in
                printf 'GPIO18%s %s %s\n' "${pin#GPIO}" "$d" "$v"
                bit=$((bit + 1))
            done
        done
        echo "Muxed RGMII pins must be interpreted with SCU pinmux configuration."
    } > "$OUT/gpio18-pins.txt"

    # ------------------------------------------------------------ 6. eSPI / LPC / VUART
    say "[6/15] eSPI, LPC (KCS / snoop / SuperIO), VUART registers"
    # eSPI: control and status registers only (never the channel data ports).
    dump_list espi-regs.txt "eSPI 0x1e6ee000" 0x1e6ee000 \
        0x000:CTRL 0x004:STS 0x008:INT_STS 0x00c:INT_EN \
        0x080:CTRL2 0x084:PC_RX_SADDR 0x088:PC_RX_TADDR 0x08c:PC_RX_MASK \
        0x094:VW_SYSEVT_IEN 0x098:VW_SYSEVT 0x09c:VW_GPIO_VAL \
        0x0a0:GEN_CAP 0x0a4:CH0_CAP 0x0a8:CH1_CAP 0x0ac:CH2_CAP 0x0b0:CH3_CAP 0x0b4:CH3_CAP2 \
        0x100:VW_SYSEVT1_IEN 0x104:VW_SYSEVT1 0x110:SYSEVT_IT0 0x114:SYSEVT_IT1 0x118:SYSEVT_IT2 \
        0x120:SYSEVT1_IT0 0x124:SYSEVT1_IT1 0x128:SYSEVT1_IT2
    # Whether the firmware handles eSPI / KCS / snoop / VUART interrupts at all
    # (counts only grow if a driver services them, e.g. Virtual Wire SUS_WARN).
    {
        echo "### eSPI / LPC related interrupts (/proc/interrupts)"
        head -n 1 /proc/interrupts
        grep -i -E 'espi|kcs|snoop|lpc|vuart|ipmi|1e6ee000|1e789|1e787' /proc/interrupts
        echo
    } >> "$OUT/espi-regs.txt" 2>/dev/null
    # LPC: host interface control and address registers only (never IDR/ODR).
    dump_list lpc-regs.txt "LPC 0x1e789000" 0x1e789000 \
        0x000:HICR0 0x004:HICR1 0x008:HICR2 0x00c:HICR3 0x010:HICR4 \
        0x014:LADR3H 0x018:LADR3L 0x01c:LADR12H 0x020:LADR12L \
        0x080:HICR5 0x084:HICR6 0x088:HICR7 0x08c:HICR8 0x090:SNPWADR \
        0x098:HICR9 0x09c:HICRA 0x100:HICRB 0x104:HICRC 0x110:LADR4 0x120:LSADR12
    # VUART: only the global control / address registers (0x20-0x2c).
    dump_list vuart-regs.txt "VUART1 0x1e787000" 0x1e787000 0x020:GCRA 0x024:GCRB 0x028:ADDRL 0x02c:ADDRH
    dump_list vuart-regs.txt "VUART2 0x1e788000" 0x1e788000 0x020:GCRA 0x024:GCRB 0x028:ADDRL 0x02c:ADDRH

    # ------------------------------------------------------------ 7. other blocks
    say "[7/15] PWM/tach, ADC, watchdog, SPI controller registers"
    dump_range block-regs.txt "PWM / tach 0x1e610000" 0x1e610000 0x000 0x0fc
    dump_range block-regs.txt "ADC0 0x1e6e9000" 0x1e6e9000 0x000 0x0cc
    dump_range block-regs.txt "ADC1 0x1e6e9100" 0x1e6e9100 0x000 0x0cc
    dump_range block-regs.txt "WDT1..4 0x1e785000" 0x1e785000 0x000 0x0fc
    dump_range block-regs.txt "FMC (BMC flash) 0x1e620000" 0x1e620000 0x000 0x0fc
    dump_range block-regs.txt "SPI1 (host BIOS flash) 0x1e630000" 0x1e630000 0x000 0x0fc
    dump_range block-regs.txt "PECI controller 0x1e78b000 (control / timing)" 0x1e78b000 0x000 0x01c
else
    say "[4-7/15] skipped: MMIO disabled, non-AST2600, or /dev/mem/devmem unavailable"
    echo "MMIO disabled or unavailable: register dump skipped" > "$OUT/scu-regs.txt"
fi

# busof N : Linux bus number of AST2600 I2C controller N (0x1e78a080 + N*0x80);
# the vendor firmware may number its buses differently.
busof() {
    want=$(printf '%x' $((0x1e78a080 + $1 * 0x80)))
    for b in /sys/bus/i2c/devices/i2c-*; do
        [ -d "$b" ] || continue
        case "$(readlink -f "$b/device" 2>/dev/null)$(readlink -f "$b" 2>/dev/null)" in
            *"$want"*) echo "${b##*/i2c-}"; return ;;
        esac
    done
    echo "$1"
}

# ---------------------------------------------------------------- 8. I2C
say "[8/15] I2C buses and devices"
{
    for b in /sys/bus/i2c/devices/i2c-*; do
        [ -d "$b" ] || continue
        n=${b##*/i2c-}
        ctrl=$(readlink -f "$b/device" 2>/dev/null | sed 's|.*/||')
        [ -z "$ctrl" ] && ctrl=$(readlink -f "$b/.." 2>/dev/null | sed 's|.*/||')
        echo "bus i2c-$n  $(cat "$b/name" 2>/dev/null)  controller=$ctrl"
        for c in /sys/bus/i2c/devices/"$n"-*; do
            [ -d "$c" ] || continue
            drv=$(readlink "$c/driver" 2>/dev/null | sed 's|.*/||')
            echo "    ${c##*/}  name=$(cat "$c/name" 2>/dev/null)  driver=${drv:-<none>}"
        done
    done
} > "$OUT/i2c-devices.txt"
if [ "$SCAN" = 1 ] && have i2cdetect; then
    for b in /sys/bus/i2c/devices/i2c-*; do
        [ -d "$b" ] || continue
        n=${b##*/i2c-}
        run i2c-scan.txt "i2c-$n read scan (UU = owned by a kernel driver)" i2cdetect -y -r "$n"
    done
fi
# FRU / EEPROM contents (read through the kernel driver; reads do not modify them).
for e in /sys/bus/i2c/devices/*/eeprom; do
    [ -r "$e" ] || continue
    d=${e%/eeprom}; d=${d##*/}
    $TMO dd if="$e" of="$OUT/eeprom-$d.bin" bs=1024 count=8 2>/dev/null
    if have hexdump; then
        hexdump -C "$OUT/eeprom-$d.bin" > "$OUT/eeprom-$d.txt"
    elif have od; then
        od -t x1 "$OUT/eeprom-$d.bin" > "$OUT/eeprom-$d.txt" 2>/dev/null
    fi
done

# ---------------------------------------------------------------- 9. hwmon / iio
say "[9/15] hwmon and ADC"
: > "$OUT/hwmon-layout.txt"
for h in /sys/class/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    dev=$(readlink -f "$h/device" 2>/dev/null | sed 's|^/sys/devices/||')
    of=""
    [ -r "$h/device/of_node/compatible" ] && of=$(tr '\0' ' ' < "$h/device/of_node/compatible")
    echo "${h##*/} name=$(cat "$h/name" 2>/dev/null) device=$dev compatible=$of" >> "$OUT/hwmon-layout.txt"
    for a in "$h"/*_label "$h"/*_input "$h"/pwm[0-9]* "$h"/*_enable "$h"/*_alarm "$h"/*_max \
             "$h"/*_min "$h"/*_crit "$h"/device/*_label "$h"/device/*_input; do
        [ -f "$a" ] || continue
        echo "${a#/sys/class/hwmon/}: $(cat "$a" 2>/dev/null)" >> "$OUT/hwmon-values.txt"
    done
    # the attribute list itself (without values) for the layout comparison
    ls "$h" "$h/device" 2>/dev/null | grep -E '_(input|label)$|^pwm[0-9]+$' | sort -u | \
        sed 's/^/    /' >> "$OUT/hwmon-layout.txt"
done
: > "$OUT/iio-layout.txt"
for i in /sys/bus/iio/devices/iio:device*; do
    [ -d "$i" ] || continue
    echo "${i##*/} name=$(cat "$i/name" 2>/dev/null) of=$(readlink -f "$i/of_node" 2>/dev/null | sed 's|.*/device-tree||')" >> "$OUT/iio-layout.txt"
    ls "$i" | grep -E '^in_voltage' | sed 's/^/    /' >> "$OUT/iio-layout.txt"
    for a in "$i"/in_voltage*; do
        [ -f "$a" ] && echo "${a#/sys/bus/iio/devices/}: $(cat "$a" 2>/dev/null)" >> "$OUT/iio-values.txt"
    done
done

# ---------------------------------------------------------------- 10. serial / console
say "[10/15] UARTs, VUART and host console"
{
    echo "### /proc/tty/driver/serial"
    cat /proc/tty/driver/serial 2>/dev/null || echo "(not readable)"
    echo
    echo "### tty devices"
    for t in /sys/class/tty/ttyS* /sys/class/tty/ttyVUART* /sys/class/tty/ttyUSB* /sys/class/tty/ttyGS*; do
        [ -e "$t" ] || continue
        echo "${t##*/} device=$(readlink -f "$t/device" 2>/dev/null | sed 's|^/sys/devices/||') iomem=$(cat "$t/iomem_base" 2>/dev/null) irq=$(cat "$t/irq" 2>/dev/null)"
    done
    echo
    echo "### /dev symlinks to ttys"
    ls -l /dev 2>/dev/null | grep -E -- '-> .*tty' || echo "(none)"
    echo
    echo "### which process holds which tty (console server / SOL source)"
    for p in /proc/[0-9]*; do
        fds=$(ls -l "$p/fd" 2>/dev/null | grep -E '/dev/tty(S|VUART|USB|GS)' | sed 's/.*-> //' | sort -u | tr '\n' ' ')
        [ -n "$fds" ] && echo "pid ${p#/proc/} $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-150): $fds"
    done
} > "$OUT/serial.txt"
for f in /etc/obmc-console/*.conf /etc/obmc-console.conf /etc/*sol*.conf; do
    [ -r "$f" ] && { echo "### $f"; cat "$f"; echo; } >> "$OUT/serial.txt"
done

# ---------------------------------------------------------------- 11. network
say "[11/15] network (MAC, PHY address, NC-SI)"
{
    for n in /sys/class/net/*; do
        i=${n##*/}
        [ "$i" = lo ] && continue
        phy=$(readlink "$n/phydev" 2>/dev/null | sed 's|.*/||')
        phyid=$(cat "$n/phydev/phy_id" 2>/dev/null)
        phydrv=$(readlink "$n/phydev/driver" 2>/dev/null | sed 's|.*/||')
        echo "$i dev=$(readlink -f "$n/device" 2>/dev/null | sed 's|.*/||') phy=${phy:-<none, NC-SI or fixed>} phy_id=${phyid:--} phy_driver=${phydrv:--} mac=$(cat "$n/address" 2>/dev/null) carrier=$(cat "$n/carrier" 2>/dev/null) speed=$(cat "$n/speed" 2>/dev/null)"
    done
} > "$OUT/net-layout.txt"
run network.txt "addresses" ip addr
run network.txt "links" ip -d link
run network.txt "routes" ip route
show network.txt /etc/resolv.conf
for n in /sys/class/net/eth*; do
    [ -e "$n" ] || continue
    have ethtool && run network.txt "ethtool ${n##*/}" ethtool "${n##*/}"
    have ethtool && run network.txt "ethtool -i ${n##*/}" ethtool -i "${n##*/}"
done
grep -i -E 'ncsi|ftgmac|mdio|phy|eth[0-9]' "$OUT/dmesg.txt" > "$OUT/network-dmesg.txt" 2>/dev/null
for f in /etc/systemd/network/* /etc/network/interfaces; do
    [ -r "$f" ] && { echo "### $f"; cat "$f"; echo; } >> "$OUT/network.txt"
done

# ---------------------------------------------------------------- 12. flash
say "[12/15] SPI flash partitions"
run mtd.txt "mtd partitions" cat /proc/mtd
for m in /sys/class/mtd/mtd[0-9]*; do
    [ -d "$m" ] || continue
    case "$m" in *ro) continue ;; esac
    echo "${m##*/} name=$(cat "$m/name" 2>/dev/null) size=$(cat "$m/size" 2>/dev/null) parent=$(readlink -f "$m/device" 2>/dev/null | sed 's|^/sys/devices/||')" >> "$OUT/mtd.txt"
done
grep -i -E 'spi-nor|spi_nor|mtd|fmc|jedec' "$OUT/dmesg.txt" >> "$OUT/mtd.txt" 2>/dev/null

# ---------------------------------------------------------------- 13. LEDs, watchdog, RTC, other devices
say "[13/15] LEDs, watchdog, RTC, USB, video, PECI, device nodes"
for l in /sys/class/leds/*; do
    [ -d "$l" ] || continue
    trig=$(sed 's/.*\[\(.*\)\].*/\1/' "$l/trigger" 2>/dev/null)
    echo "${l##*/} brightness=$(cat "$l/brightness" 2>/dev/null) trigger=$trig of=$(readlink -f "$l/device/of_node" 2>/dev/null | sed 's|.*/device-tree||')" >> "$OUT/leds.txt"
done
[ -e "$OUT/leds.txt" ] || echo "(no LEDs in /sys/class/leds)" > "$OUT/leds.txt"
for w in /sys/class/watchdog/watchdog*; do
    [ -d "$w" ] || continue
    echo "${w##*/} identity=$(cat "$w/identity" 2>/dev/null) state=$(cat "$w/state" 2>/dev/null) timeout=$(cat "$w/timeout" 2>/dev/null) bootstatus=$(cat "$w/bootstatus" 2>/dev/null) device=$(readlink -f "$w/device" 2>/dev/null | sed 's|.*/||')" >> "$OUT/watchdog.txt"
done
[ -e "$OUT/watchdog.txt" ] || echo "(no watchdog class devices)" > "$OUT/watchdog.txt"
for r in /sys/class/rtc/rtc*; do
    [ -d "$r" ] || continue
    echo "${r##*/} name=$(cat "$r/name" 2>/dev/null) device=$(readlink -f "$r/device" 2>/dev/null | sed 's|.*/||') hctosys=$(cat "$r/hctosys" 2>/dev/null)" >> "$OUT/rtc.txt"
done
[ -e "$OUT/rtc.txt" ] || echo "(no RTC)" > "$OUT/rtc.txt"
have hwclock && run rtc-values.txt "hwclock" hwclock -r
{
    echo "### character devices that show which hardware blocks are in use"
    ls -l /dev 2>/dev/null | grep -E 'ipmi|kcs|bt-bmc|snoop|lpc|espi|vuart|ttyS|video|peci|i3c|mctp|aspeed|i2c-|mtd|watchdog|rtc|hidg|uinput|gpiochip|jtag|pcc' \
        | awk '{print $1, $NF}'
    echo
    echo "### USB device controller / gadgets"
    ls /sys/class/udc 2>/dev/null
    ls -R /sys/kernel/config/usb_gadget 2>/dev/null | head -n 200
    echo
    echo "### PECI"
    ls -l /sys/bus/peci/devices 2>/dev/null
    ls /sys/bus/peci/drivers 2>/dev/null | sed 's/^/    driver: /'
    echo
    echo "### I3C"
    ls -l /sys/bus/i3c/devices 2>/dev/null
    echo
    echo "### chassis intrusion"
    for a in /sys/class/hwmon/hwmon*/intrusion*; do
        [ -e "$a" ] && echo "$a: $(cat "$a" 2>/dev/null)"
    done
} > "$OUT/dev-nodes.txt"

# ---------------------------------------------------------------- 13b. debug console and VGA
say "[13b/15] BMC debug console and VGA / video"
{
    echo "### BMC debug console"
    echo "kernel cmdline: $(cat /proc/cmdline 2>/dev/null)"
    [ -r /proc/device-tree/chosen/stdout-path ] && \
        echo "device tree /chosen/stdout-path: $(tr -d '\0' < /proc/device-tree/chosen/stdout-path)"
    [ -r /proc/device-tree/chosen/bootargs ] && \
        echo "device tree /chosen/bootargs: $(tr -d '\0' < /proc/device-tree/chosen/bootargs)"
    echo "active consoles (/proc/consoles):"
    cat /proc/consoles 2>/dev/null | sed 's/^/    /'
    echo "login prompts (getty) on:"
    ps w 2>/dev/null | grep -E '[g]etty' | sed 's/^/    /'
    # UART blocks in the device tree (AST2600: uart1..5 at 0x1e783000, 0x1e78d000,
    # 0x1e78e000, 0x1e78f000, 0x1e784000; uart6..13 at 0x1e790000..)
    echo "UART nodes in the device tree:"
    grep -E '/serial@[0-9a-f]+ ' "$OUT/dt-enabled-nodes.txt" 2>/dev/null | sed 's/^/    /'
    for t in $(cat /proc/consoles 2>/dev/null | awk '{print $1}'); do
        [ -e "/dev/$t" ] || continue
        have stty && echo "line settings of /dev/$t: $(stty -F "/dev/$t" 2>/dev/null | tr '\n' ' ')"
    done
    echo
    echo "### VGA (GFX display controller 0x1e6e6000) and KVM video engine (0x1e700000)"
    echo "device tree nodes:"
    grep -E '/(display|gfx|video)@' "$OUT/dt-enabled-nodes.txt" 2>/dev/null | sed 's/^/    /'
    echo "framebuffer / DRM / video devices:"
    ls -l /dev/fb* /dev/dri/* /dev/video* 2>/dev/null | awk '{print "    " $1, $NF}'
    ls /sys/class/drm 2>/dev/null | sed 's/^/    drm: /'
    for v in /sys/class/video4linux/*; do
        [ -e "$v" ] && echo "    ${v##*/}: $(cat "$v/name" 2>/dev/null)"
    done
    echo "reserved memory (VGA / video buffers):"
    ls /proc/device-tree/reserved-memory 2>/dev/null | sed 's/^/    /'
    echo "kernel messages:"
    grep -i -E 'aspeed-video|aspeed_video|gfx|vga|drm|fb[0-9]|framebuffer|video engine' \
        "$OUT/dmesg.txt" 2>/dev/null | sed 's/^/    /'
    echo "KVM / video processes:"
    ps w 2>/dev/null | grep -i -E '[k]vm|[v]ideo|[o]bmc-ikvm|[v]nc' | sed 's/^/    /'
} > "$OUT/console-vga.txt"
if [ -n "$DEVMEM" ]; then
    {
        echo "SCU500 hw strap 1: $(rd 0x1e6e2500)  (VGA memory size / VGA enable straps)"
        echo "SCU0C0 misc control: $(rd 0x1e6e20c0)"
    } >> "$OUT/console-vga.txt"
    dump_range block-regs.txt "GFX (VGA display) 0x1e6e6000" 0x1e6e6000 0x000 0x0fc
    dump_range block-regs.txt "Video engine (KVM) 0x1e700000" 0x1e700000 0x000 0x0fc
fi

# ---------------------------------------------------------------- 13c. external chips
say "[13c/15] external chips: models and kernel drivers"
phy_model() {
    case "$1" in
        0x001cc916) echo "Realtek RTL8211F/FS" ;;
        0x001cc915) echo "Realtek RTL8211E" ;;
        0x001cc912) echo "Realtek RTL8211B" ;;
        0x001cc914) echo "Realtek RTL8211DN" ;;
        0x01410dd*) echo "Marvell 88E1510/1512" ;;
        0x01410cc*) echo "Marvell 88E1111" ;;
        0x600d84a*) echo "Broadcom BCM54210E" ;;
        0x0022162*) echo "Micrel/Microchip KSZ9031" ;;
        0x2000a23*) echo "TI DP83867" ;;
        *) echo "unknown (look up the OUI)" ;;
    esac
}
{
    echo "### chips declared in the device tree (node: compatible)"
    echo "# children of I2C / SPI / FMC / MDIO controllers are the external chips"
    find /proc/device-tree -name compatible 2>/dev/null | sort | while read -r c; do
        node=$(dirname "$c" | sed 's|^/proc/device-tree||')
        case "$node" in
            */i2c@*/*|*/i2c-bus@*/*|*/spi@*/*|*/fmc@*/*|*/mdio@*/*|*/ethernet-phy*|*/leds*|*/iio-hwmon*|*/gpio-keys*|*/pwm-fan*)
                st=""
                [ -r "$(dirname "$c")/status" ] && st=" [$(tr -d '\0' < "$(dirname "$c")/status")]"
                reg=""
                [ -r "$(dirname "$c")/reg" ] && have od && \
                    reg=" reg=$(od -A n -t x1 "$(dirname "$c")/reg" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
                echo "$node: $(tr '\0' ' ' < "$c")$st$reg"
                ;;
        esac
    done
    echo
    echo "### I2C chips the kernel knows (bus-address: name -> driver)"
    for d in /sys/bus/i2c/devices/[0-9]*-*; do
        [ -d "$d" ] || continue
        drv=$(readlink "$d/driver" 2>/dev/null | sed 's|.*/||')
        echo "${d##*/}: $(cat "$d/name" 2>/dev/null) -> ${drv:-<no driver bound>}"
    done
    echo
    echo "### SPI flash chips"
    for d in /sys/bus/spi/devices/*; do
        [ -d "$d" ] || continue
        drv=$(readlink "$d/driver" 2>/dev/null | sed 's|.*/||')
        line="${d##*/}: modalias=$(cat "$d/modalias" 2>/dev/null) driver=${drv:-<none>}"
        [ -r "$d/spi-nor/jedec_id" ] && line="$line jedec_id=$(cat "$d/spi-nor/jedec_id")"
        [ -r "$d/spi-nor/manufacturer" ] && line="$line manufacturer=$(cat "$d/spi-nor/manufacturer")"
        [ -r "$d/spi-nor/partname" ] && line="$line part=$(cat "$d/spi-nor/partname")"
        echo "$line"
    done
    grep -i -E 'spi-nor|spi_nor|jedec|found .* flash|detected|mx25|mx66|w25q|n25q|mt25q|s25fl|gd25' \
        "$OUT/dmesg.txt" 2>/dev/null | sed 's/^/    dmesg: /'
    echo
    echo "### Ethernet PHYs"
    for n in /sys/class/net/*; do
        [ -e "$n/phydev/phy_id" ] || continue
        id=$(cat "$n/phydev/phy_id")
        echo "${n##*/}: phy=$(readlink "$n/phydev" | sed 's|.*/||') phy_id=$id ($(phy_model "$id")) driver=$(readlink "$n/phydev/driver" 2>/dev/null | sed 's|.*/||')"
    done
    for p in /sys/bus/mdio_bus/devices/*; do
        [ -e "$p/phy_id" ] || continue
        id=$(cat "$p/phy_id")
        echo "${p##*/}: phy_id=$id ($(phy_model "$id"))"
    done
    echo "NC-SI (network controller behind the NC-SI port):"
    grep -i 'ncsi' "$OUT/dmesg.txt" 2>/dev/null | sed 's/^/    dmesg: /' | head -n 20
    echo
    echo "### hwmon chips (sensor driver names)"
    for h in /sys/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        echo "${h##*/}: $(cat "$h/name" 2>/dev/null) on $(readlink -f "$h/device" 2>/dev/null | sed 's|.*/||')"
    done
    echo
    echo "### PMBus power supplies (manufacturer / model, if a pmbus driver is bound)"
    for d in /sys/kernel/debug/pmbus/hwmon*; do
        [ -d "$d" ] || continue
        echo "${d##*/}: mfr_id=$(cat "$d/mfr_id" 2>/dev/null) model=$(cat "$d/mfr_model" 2>/dev/null) revision=$(cat "$d/mfr_revision" 2>/dev/null) serial=$(cat "$d/mfr_serial" 2>/dev/null)"
    done
    echo
    echo "### RTC / EEPROM / LED / watchdog chips"
    for r in /sys/class/rtc/rtc*; do
        [ -d "$r" ] && echo "${r##*/}: $(cat "$r/name" 2>/dev/null)"
    done
    for e in /sys/bus/i2c/devices/*/eeprom; do
        [ -e "$e" ] || continue
        d=${e%/eeprom}; d=${d##*/}
        echo "$d: $(cat "/sys/bus/i2c/devices/$d/name" 2>/dev/null) eeprom, $(wc -c < "$e" 2>/dev/null) bytes"
    done
    echo
    echo "### every kernel driver bound to a device (bus: device -> driver)"
    for bus in platform i2c spi mdio_bus i3c peci usb; do
        for d in /sys/bus/$bus/devices/*; do
            [ -e "$d/driver" ] || continue
            echo "$bus: ${d##*/} -> $(readlink "$d/driver" | sed 's|.*/||')"
        done
    done
    echo
    echo "### loaded kernel modules"
    awk '{print $1}' /proc/modules 2>/dev/null | sort | tr '\n' ' '
    echo
} > "$OUT/chips.txt"
# Identify the known ceb-gnrd chips directly over I2C (read-only SMBus reads),
# also when the firmware has no kernel driver for them.  -n turns it off.
hex2ascii() {
    for x in $*; do
        case "$x" in 0x*) ;; *) continue ;; esac
        v=$((x))
        [ "$v" -ge 32 ] && [ "$v" -lt 127 ] || continue
        o=$(printf '%03o' "$v")
        printf "\\$o"
    done
}
chip_read() {
    echo "\$ i2cget $*" >> "$OUT/i2c-probe.log"
    $TMO i2cget "$@" 2>> "$OUT/i2c-probe.log"
    cr_rc=$?
    echo "exit=$cr_rc" >> "$OUT/i2c-probe.log"
    return "$cr_rc"
}
if [ "$PROBE" = 1 ] && have i2cget; then
    B6=$(busof 6); B7=$(busof 7); B9=$(busof 9); B10=$(busof 10)
    {
        echo "### chip identification over I2C (controller -> bus here: I2C7=i2c-$B6, I2C8=i2c-$B7, I2C10=i2c-$B9, I2C11=i2c-$B10)"
        echo "# temperature sensors (NST175 / LM75 family): TEMP reg0, CONF reg1, THYST reg2, TOS reg3"
        echo "# an LM75-compatible chip at power-on has THYST 75 C and TOS 80 C"
        for a in 0x48 0x49 0x4a 0x4b; do
            t=$(chip_read -y "$B6" $a 0x00 w 2>/dev/null)
            if [ -z "$t" ]; then echo "i2c-$B6 $a: no answer"; continue; fi
            c=$(chip_read -y "$B6" $a 0x01 b 2>/dev/null)
            h=$(chip_read -y "$B6" $a 0x02 w 2>/dev/null)
            o=$(chip_read -y "$B6" $a 0x03 w 2>/dev/null)
            if [ -z "$c" ] || [ -z "$h" ] || [ -z "$o" ]; then
                echo "i2c-$B6 $a: incomplete register read temp=$t conf=$c thyst=$h tos=$o (see i2c-probe.log)"
                continue
            fi
            msb=$(( t & 0xff )); [ "$msb" -ge 128 ] && msb=$((msb - 256))
            half=$(( (t >> 15) & 1 ))
            echo "i2c-$B6 $a: temp=$msb.$((half * 5)) C conf=$c thyst=$(( h & 0xff )) C tos=$(( o & 0xff )) C (raw $t $h $o)"
        done
        echo
        echo "# RTC NCT3015Y / NCT3018Y at 0x6f: registers 0x00-0x1f"
        r=""
        i=0
        while [ $i -lt 32 ]; do
            v=$(chip_read -y "$B9" 0x6f $i b 2>/dev/null) || { r="no answer"; break; }
            r="$r ${v#0x}"
            i=$((i + 1))
        done
        echo "i2c-$B9 0x6f:$r"
        echo
        echo "# FRU EEPROM: a 24C08 (1 KiB) answers at 0x50-0x53, a 24C02 only at 0x50"
        for a in 0x50 0x51 0x52 0x53 0x54 0x55 0x56 0x57; do
            v=$(chip_read -y "$B10" $a 0x00 b 2>/dev/null) && echo "i2c-$B10 $a: answers (byte0=$v)"
        done
        if [ ! -e "/sys/bus/i2c/devices/$(printf '%s-%04x' "$B10" 0x50)/eeprom" ]; then
            r=""; i=0
            while [ $i -lt 16 ]; do
                v=$(chip_read -y "$B10" 0x50 $i b 2>/dev/null) || break
                r="$r ${v#0x}"; i=$((i + 1))
            done
            echo "i2c-$B10 0x50 first 16 bytes:$r  (FRU common header starts with 01)"
        fi
        echo
        echo "# PMBus PSUs: PMBUS_REVISION 0x98, MFR_ID 0x99, MFR_MODEL 0x9a, MFR_REVISION 0x9b"
        for a in 0x58 0x59 0x5a; do
            rev=$(chip_read -y "$B7" $a 0x98 b 2>/dev/null)
            if [ -z "$rev" ]; then echo "i2c-$B7 $a: no answer (slot empty?)"; continue; fi
            id=$(chip_read -y "$B7" $a 0x99 s 2>/dev/null)
            md=$(chip_read -y "$B7" $a 0x9a s 2>/dev/null)
            mr=$(chip_read -y "$B7" $a 0x9b s 2>/dev/null)
            echo "i2c-$B7 $a: pmbus_rev=$rev MFR_ID='$(hex2ascii $id)' MFR_MODEL='$(hex2ascii $md)' MFR_REVISION='$(hex2ascii $mr)'"
        done
        echo
    } >> "$OUT/chips.txt" 2>&1
fi
# PHY IDs are collected through sysfs above. Do not run mii-tool -v here:
# reading all PHY registers can acknowledge latched status/interrupts.

# ---------------------------------------------------------------- 14. IPMI
say "[14/15] IPMI (if ipmitool exists on this firmware)"
if have ipmitool; then
    run ipmi.txt "mc info" ipmitool mc info
    run ipmi.txt "mc guid" ipmitool mc guid
    run ipmi.txt "fru" ipmitool fru print
    run ipmi.txt "sdr" ipmitool sdr elist
    run ipmi.txt "sensor" ipmitool sensor
    run ipmi.txt "sel" ipmitool sel elist
    run ipmi.txt "chassis status" ipmitool chassis status
    run ipmi.txt "lan 1" ipmitool lan print 1
    run ipmi.txt "lan 2" ipmitool lan print 2
    run ipmi.txt "sol" ipmitool sol info
else
    echo "ipmitool is not installed on this firmware" > "$OUT/ipmi.txt"
fi

# ---------------------------------------------------------------- 15. ceb-gnrd checklist
# Every hardware function the ceb-gnrd firmware uses, with the value the new
# firmware expects next to what this firmware shows.  On the old vendor firmware
# a different value is not automatically wrong, but every difference must be
# explained before the new image is deployed.
say "[15/15] ceb-gnrd checklist (expected by the new firmware vs found here)"
CK=$OUT/ceb-gnrd-checklist.txt
ck() { printf '%s\n' "$*" >> "$CK"; }
sect() { ck ""; ck "==== $*"; }

ck "ceb-gnrd checklist - $HOST $STAMP"
ck "EXPECTED = what the ceb-gnrd firmware uses; FOUND = this firmware."
ck "AST2600 Linux numbering: i2c-N is controller 0x1e78a080 + N*0x80 (schematic I2C(N+1))."

sect "GPIO (needs devmem; direction / level from the GPIO registers)"
if [ -s "$OUT/gpio-pins.txt" ] && grep -q '^GPIOA0' "$OUT/gpio-pins.txt"; then
    for e in \
        "GPIOG6 out BMC_FRU_WP:FRU EEPROM write protect (low = writable)" \
        "GPIOI5 out BMC_SYS_ALERT_LED:system alert LED" \
        "GPIOI6 out BMC_FAN_BMC_OVERRIDE_N:high = BMC owns the fan PWM (CPLD mux)" \
        "GPIOM1 out BMC_BIOS_FLASH_SELECT:BIOS flash to BMC (high, only during update)" \
        "GPIOM2 in  BMC_POWER_BUTTON_INPUT:front panel power button (active low)" \
        "GPIOM7 in  BMC_BIOS_BOOT_OK:BIOS POST complete (high)" \
        "GPIOP7 out BMC_HBLED_N:BMC heartbeat LED to CPLD" \
        "GPIOS4 in  PCB_VER0:board revision strap" \
        "GPIOS5 in  PCB_VER1:board revision strap" \
        "GPIOS6 in  PCB_VER2:board revision strap" \
        "GPIOS7 in  CFG_VER0:configuration strap" \
        "GPIOV0 in  BMC_UID_BUTTON_N:UID button (active low)" \
        "GPIOV1 out BMC_UID_LED:UID / identify LED" \
        "GPIOV2 out BMC_CPU_POWER_BUTTON:power button pulse to the CPU (active low)" \
        "GPIOV3 out BMC_CPU_RESET:reset pulse to the CPU (active low)" \
        "GPIOV4 in  BMC_CPU_PWRGD:host power good (host on = high)"
    do
        pin=${e%% *}; rest=${e#* }; dir=${rest%% *}; rest=${rest#* }; rest=${rest# }
        sig=${rest%%:*}; what=${rest#*:}
        got=$(awk -v p="$pin" '$1 == p {print "dir=" $3 " value=" $4}' "$OUT/gpio-pins.txt")
        ck "$(printf '%-7s %-24s expected %-4s found %-18s %s' "$pin" "$sig" "$dir" "${got:-?}" "$what")"
    done
    ck "(a pin muxed to another function shows a meaningless value: check scu-regs.txt)"
else
    ck "not available (no devmem): compare gpio-kernel.txt / gpio-sysfs-exported.txt by hand"
fi

sect "I2C devices"
scan_has() {
    # scan_has BUS ADDR -> the i2cdetect cell (UU / address / --) or "?" without -s
    [ -s "$OUT/i2c-scan.txt" ] || { echo "?"; return; }
    sed -n "/^### i2c-$1 /,/^### /p" "$OUT/i2c-scan.txt" | awk -v a="$2" '
        BEGIN { a = tolower(a); sub(/^0x/, "", a); row = substr(a, 1, 1) "0:"; col = ("0x" substr(a, 2, 1)) + 0 }
        $1 == row { print $(col + 2); exit }'
}
for e in \
    "6 0x48 EnvTemp_Inlet (NST175, lm75)" "6 0x49 EnvTemp_Outlet" "6 0x4a BoardTemp_PCIe" "6 0x4b BoardTemp_M2" \
    "7 0x58 CRPS PSU0 (PMBus, 0-2 PSUs present)" "7 0x59 CRPS PSU1" "7 0x5a CRPS PSU2" \
    "9 0x6f RTC NCT3015Y" "10 0x50 FRU EEPROM FM24C08 (0x50-0x53)"
do
    set -- $e
    bus=$(busof "$1") addr=$2; shift 2
    dev=$(printf '%s-%04x' "$bus" "$addr")
    if [ -d "/sys/bus/i2c/devices/$dev" ]; then
        drv=$(readlink "/sys/bus/i2c/devices/$dev/driver" 2>/dev/null | sed 's|.*/||')
        got="kernel device $dev ($(cat "/sys/bus/i2c/devices/$dev/name" 2>/dev/null), driver ${drv:-none})"
    else
        got="no kernel device; scan cell: $(scan_has "$bus" "$addr")"
    fi
    ck "$(printf 'i2c-%-2s %s  %-38s found: %s' "$bus" "$addr" "$*" "$got")"
done
ck "bus controllers here:"
grep '^bus ' "$OUT/i2c-devices.txt" 2>/dev/null | sed 's/^/    /' >> "$CK"
[ -s "$OUT/i2c-scan.txt" ] || ck "(no I2C scan: run with -s to see devices the vendor firmware drives from user space)"

sect "network"
ck "expected: 1e680000.ethernet = RJ45 via RTL8211FS, PHY address 2 (…:02), RGMII, static 192.168.185.200"
ck "expected: 1e670000.ethernet = NC-SI to the Intel E810 (no PHY), DHCP, only up while the host is on"
ck "found:"
sed 's/^/    /' "$OUT/net-layout.txt" >> "$CK" 2>/dev/null
[ -n "$DEVMEM" ] && ck "SCU340/350 (MAC clock delays) found: $(rd 0x1e6e2340) $(rd 0x1e6e2350)"

sect "BMC debug console"
ck "expected: UART5 = ttyS4 (serial@1e784000), 115200 8N1"
ck "found: $(grep -o 'console=[^ ]*' /proc/cmdline 2>/dev/null | tr '\n' ' ')/proc/consoles: $(awk '{print $1}' /proc/consoles 2>/dev/null | tr '\n' ' ')"

sect "host interfaces (eSPI / KCS / POST code / host CPU serial console = SOL)"
ck "expected: eSPI mode (strap SCU510), Peripheral + Virtual Wire channels ready"
ck "expected: KCS3 at I/O 0xCA2/0xCA3 (IPMI KCS), POST code snoop on port 0x80"
ck "expected: VUART1 at I/O 0x3F8 (host COM1), SerIRQ 4 -> ttyVUART0 = SOL"
if [ -n "$DEVMEM" ]; then
    c=$(rd 0x1e6ee000); s=$(rd 0x1e6ee098)
    case "$c$s" in *-*) ck "eSPI registers not readable" ;; *)
        ck "found eSPI CTRL=$c (bit1 peripheral ready=$(( (c >> 1) & 1 )), bit3 VW ready=$(( (c >> 3) & 1 ))) SYSEVT=$s (boot done=$(( (s >> 20) & 1 )), boot status=$(( (s >> 23) & 1 )))" ;;
    esac
    h=$(rd 0x1e789014); l=$(rd 0x1e789018)
    case "$h$l" in *-*) ;; *) ck "found KCS3 address (LADR3H/L) = 0x$(printf '%02x%02x' $((h & 0xff)) $((l & 0xff)))  HICR0=$(rd 0x1e789000)" ;; esac
    a=$(rd 0x1e789090)
    case "$a" in *-*) ;; *) ck "found snoop address 0 (SNPWADR) = 0x$(printf '%04x' $((a & 0xffff)))  HICR5=$(rd 0x1e789080)" ;; esac
    ga=$(rd 0x1e787020); gb=$(rd 0x1e787024); al=$(rd 0x1e787028); ah=$(rd 0x1e78702c)
    case "$ga$gb$al$ah" in *-*) ;; *)
        ck "found VUART1 enable=$((ga & 1)) address=0x$(printf '%02x%02x' $((ah & 0xff)) $((al & 0xff))) SerIRQ=$(( (gb >> 4) & 0xf ))" ;;
    esac
else
    ck "found: no devmem; see dev-nodes.txt (ipmi-kcs*, aspeed-lpc-snoop*, ttyVUART*) and serial.txt"
fi
ck "device nodes here: $(ls /dev 2>/dev/null | grep -E 'kcs|ipmi|snoop|espi|VUART' | tr '\n' ' ')"
# Host CPU serial console (SOL), not the BMC debug port: the process that reads the
# host UART (obmc-console-server on ttyVUART0 here; the vendor firmware may use
# another program or another UART).  Shells on the BMC debug port are left out.
ck "host CPU serial console (SOL) source, i.e. the process holding the host UART:"
grep -E '^pid ' "$OUT/serial.txt" 2>/dev/null | grep -v -E ' -?(ba)?sh |getty|bmc-hw-dump' \
    | sed 's/^/    /' >> "$CK"

sect "ADC (16 channels, voltage monitoring)"
ck "expected: ADC0-15 enabled, internal 2.5 V reference on both engines"
if [ -n "$DEVMEM" ]; then
    for b in 0x1e6e9000 0x1e6e9100; do
        r=$(rd $b)
        case "$r" in *-*) continue ;; esac
        ref=$(( (r >> 6) & 3 ))
        case $ref in 0) ref="2.5V internal" ;; 1) ref="1.2V internal" ;; *) ref="external ($ref)" ;; esac
        ck "found engine $b ctrl=$r reference=$ref channels-enabled=0x$(printf '%02x' $(( (r >> 16) & 0xff )))"
    done
fi
ck "iio devices here: $(grep -c '^iio:' "$OUT/iio-layout.txt" 2>/dev/null)"

sect "fans"
ck "expected: 6 headers, PWM0-5 at 25 kHz and TACH0-5, PWM owned by the BMC when GPIOI6 is high"
grep -E 'pwm|fan' "$OUT/hwmon-layout.txt" 2>/dev/null | head -n 30 | sed 's/^/    found /' >> "$CK"

sect "temperatures / CPU"
ck "expected: CPU and DIMM temperatures over PECI (peci0), board temperatures on i2c-6"
ck "found PECI devices: $(ls /sys/bus/peci/devices 2>/dev/null | tr '\n' ' ')"
ck "found hwmon names: $(cat /sys/class/hwmon/hwmon*/name 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ',')"

sect "flash"
ck "expected: BMC flash 64 MiB on FMC CS0 (u-boot 0x0, env 0xe0000, kernel 0x100000, rofs 0xa00000, rwfs 0x3600000)"
ck "expected: host BIOS 64 MiB on SPI1 CS0 (MX25U51245G), shared through GPIOM1"
grep -E '^(dev:|mtd[0-9])' "$OUT/mtd.txt" 2>/dev/null | head -n 20 | sed 's/^/    found /' >> "$CK"

sect "LEDs, watchdog, RTC, chassis intrusion"
ck "expected LEDs: bmc-heartbeat (GPIOP7, heartbeat trigger), fault (GPIOI5), identify (GPIOV1)"
sed 's/^/    found /' "$OUT/leds.txt" >> "$CK" 2>/dev/null
ck "expected watchdog: WDT1, systemd runtime watchdog 120 s, SoC reset (not full chip)"
sed 's/^/    found /' "$OUT/watchdog.txt" >> "$CK" 2>/dev/null
[ -n "$DEVMEM" ] && ck "    found WDT1 control=$(rd 0x1e78500c) reset-mask=$(rd 0x1e78501c) $(rd 0x1e785020)"
ck "expected RTC: NCT3015Y on i2c-9 0x6f as rtc0, internal AST2600 RTC disabled"
sed 's/^/    found /' "$OUT/rtc.txt" >> "$CK" 2>/dev/null
ck "expected chassis intrusion: AST2600 CHASI# latch (hwmon intrusion0_alarm)"
grep -A3 'chassis intrusion' "$OUT/dev-nodes.txt" 2>/dev/null | sed '1d; s/^/    found /' >> "$CK"

sect "external chips (models and drivers, details in chips.txt)"
for e in \
    "RJ45 PHY|Realtek RTL8211FS (phy_id 0x001cc916, MII OUI 00:07:32 model 17), driver 'RTL8211F Gigabit Ethernet'|phy_id=|product info|vendor" \
    "BMC flash|Winbond W25Q512JV 64 MiB on FMC (jedec ef4020)|fmc|1e620000|w25q|winbond" \
    "BIOS flash|Macronix MX25U51245G 64 MiB on SPI1 (jedec c2953a)|spi1|1e630000|mx25|macronix" \
    "RTC|Nuvoton NCT3015Y, driver rtc-nct3018y (name nct3018y)|^rtc|0x6f" \
    "FRU EEPROM|FM24C08 (24c08), driver at24|eeprom|answers|first 16" \
    "temperatures|4x NST175 at i2c-6 0x48-0x4b, driver lm75 (created by dbus-sensors)|lm75|tmp75|nst175|temp=" \
    "PSU|CRPS PMBus modules at i2c-7 0x58-0x5a, driver pmbus|pmbus|^7-00|MFR_|slot empty" \
    "NC-SI NIC|Intel E810 behind NC-SI|ncsi" \
    "fans|AST2600 PWM/tach, driver aspeed-g6-pwm-tach (hwmon)|pwm|tach" \
    "ADC|AST2600 ADC, driver aspeed_adc (iio)|adc"
do
    what=${e%%|*}; rest=${e#*|}; exp=${rest%%|*}; pat=${rest#*|}
    ck "$what: expected $exp"
    grep -i -E "$pat" "$OUT/chips.txt" 2>/dev/null | grep -v '^#' | head -n 8 | sed 's/^/    found /' >> "$CK"
done

sect "KVM, VGA, virtual media, I3C"
ck "expected: video engine video@1e700000 and VGA display@1e6e6000 enabled; USB virtual hub enabled (virtual media / KVM keyboard)"
grep -E '/(video|display|usb-vhub|usb)@' "$OUT/dt-enabled-nodes.txt" 2>/dev/null | sed 's/^/    found /' >> "$CK"
ck "    found USB device controllers: $(ls /sys/class/udc 2>/dev/null | tr '\n' ' ')"
ck "expected: I3C3 (Linux i3c2) enabled for the CPU, other I3C controllers disabled"
grep -E '/i3c@' "$OUT/dt-enabled-nodes.txt" 2>/dev/null | sed 's/^/    found /' >> "$CK"

sect "power control (how this firmware drives the host)"
ck "expected: x86-power-control using the GPIOs above (PowerOk=PWRGD, PostComplete=BOOT_OK, PowerOut, ResetOut)"
ck "processes holding GPIO lines (gpioinfo 'used'):"
grep -E '\[used\]|"[a-z]' "$OUT/gpio-kernel.txt" 2>/dev/null | grep -v unused | head -n 40 | sed 's/^/    /' >> "$CK"
ck "power / host related processes:"
grep -i -E 'power|chassis|host|state|ipmi|kcs|sol|console|fan|pid' "$OUT/processes.txt" 2>/dev/null \
    | grep -v -E 'grep|\[k' | head -n 40 | sed 's/^/    /' >> "$CK"

# ---------------------------------------------------------------- porting configuration supplement
say "[port-guide] memory, clocks, bus bindings, USB and board configuration"

# Small text attributes only. Do not traverse arbitrary debugfs files: some
# trigger transactions, consume trace buffers or block waiting for events.
attr() {
    afile=$1; shift
    for apath in "$@"; do
        [ -f "$apath" ] && [ -r "$apath" ] || continue
        {
            echo "### $apath"
            $TMO head -c "${ATTR_LIMIT:-65536}" "$apath" 2>&1
            echo "[bounded to ${ATTR_LIMIT:-65536} bytes per attribute]"
            echo
        } >> "$OUT/$afile"
    done
}

binding() {
    bfile=$1 bdev=$2
    [ -d "$bdev" ] || return
    {
        echo "### $bdev"
        echo "device=$(readlink -f "$bdev" 2>/dev/null)"
        echo "driver=$(readlink -f "$bdev/driver" 2>/dev/null)"
        echo "of_node=$(readlink -f "$bdev/of_node" 2>/dev/null)"
    } >> "$OUT/$bfile"
    attr "$bfile" "$bdev/uevent" "$bdev/modalias" "$bdev/resource" \
        "$bdev/power/runtime_status"
}

for f in memory-config memory-regs clock-config mac-regs bus-bindings \
         usb-config flash-config board-config hardware-limits; do
    echo "bmc-hw-dump format=2: $f" > "$OUT/$f.txt"
done

attr memory-config.txt /proc/meminfo /proc/iomem /proc/buddyinfo /proc/pagetypeinfo \
    /proc/vmstat /proc/swaps /sys/kernel/mm/cma/*/count
attr memory-config.txt /sys/class/graphics/fb*/name \
    /sys/class/graphics/fb*/virtual_size /sys/class/graphics/fb*/bits_per_pixel \
    /sys/class/graphics/fb*/stride /sys/class/graphics/fb*/modes
for d in /sys/class/drm/card*-*; do
    attr memory-config.txt "$d/status" "$d/enabled" "$d/modes"
    [ -r "$d/edid" ] && run memory-config.txt "cached display EDID $d" od -t x1 "$d/edid"
done
for d in /sys/class/video4linux/*; do
    binding usb-config.txt "$d"
    attr usb-config.txt "$d/name" "$d/dev" "$d/index"
    if have v4l2-ctl; then
        run usb-config.txt "video configuration ${d##*/} (no streaming)" \
            v4l2-ctl --device "/dev/${d##*/}" --all
    fi
done
for d in /sys/devices/system/edac/mc/mc*; do
    binding memory-config.txt "$d"
    attr memory-config.txt "$d/mc_name" "$d/size_mb" "$d/ce_count" "$d/ue_count" \
        "$d/seconds_since_reset" "$d"/dimm*/dimm_label "$d"/dimm*/size \
        "$d"/dimm*/dimm_mem_type "$d"/dimm*/dimm_dev_type
done
if [ -d /proc/device-tree ]; then
    # Preserve binary cells as bytes. BusyBox od -x is supported on the vendor
    # firmware too; include byte order explicitly rather than decoding as host.
    find /proc/device-tree -type f 2>/dev/null | sort | while read -r p; do
        case "$p" in
            */memory@*/reg|*/reserved-memory/*/reg|*/reserved-memory/*/size|\
            */chosen/aspeed,*|*/chosen/bootargs|*/chosen/stdout-path)
                echo "### ${p#/proc/device-tree} (raw bytes; DT cells are big-endian)"
                $TMO od -t x1 "$p" 2>&1
                ;;
        esac
    done >> "$OUT/memory-config.txt"
    find /proc/device-tree -type f 2>/dev/null | sort | while read -r p; do
        case "${p##*/}" in
            reg|ranges|dma-ranges|clocks|clock-frequency|assigned-*|resets|\
            interrupts|interrupt-parent|pinctrl-[0-9]*|*gpios|bus-width|\
            spi-*|aspeed,*|phy-handle|phy-mode|phy-connection-type|\
            scl-*|i2c-scl-*|'#address-cells'|'#size-cells')
                echo "### ${p#/proc/device-tree} (bytes; DT cells are big-endian)"
                $TMO head -c 65536 "$p" | od -t x1
                ;;
        esac
    done > "$OUT/dt-hardware-cells.txt"
fi
{
    echo "### available collection tools"
    for t in devmem timeout dtc gpioinfo gpiodetect i2cget i2cdetect \
        ethtool ip busctl systemctl hwclock ipmitool journalctl; do
        command -v "$t" 2>/dev/null || echo "SKIP: $t not installed"
    done
    echo "SCAN=$SCAN PROBE=$PROBE REGS=$REGS DEVMEM=${DEVMEM:-unavailable}"
} >> "$OUT/hardware-limits.txt"
attr clock-config.txt /sys/kernel/debug/clk/clk_summary \
    /sys/kernel/debug/clk/clk_dump
for d in /sys/kernel/debug/pinctrl/*; do
    attr clock-config.txt "$d/pinconf-pins" "$d/pinconf-groups" "$d/pins" \
        "$d/gpio-ranges" "$d/pinmux-functions"
done

if [ -n "$DEVMEM" ]; then
    # Registers named by the pinned U-Boot sdram_ast2600.h. No DRAM contents,
    # test activation, PHY indirect access, or writes to unlock keys.
    dump_list memory-regs.txt "AST2600 SDRAM controller 0x1e6e0000" 0x1e6e0000 \
        0x004:CONFIG 0x00c:REFRESH 0x010:AC_TIMING0 0x014:AC_TIMING1 \
        0x018:AC_TIMING2 0x01c:AC_TIMING3 0x020:MR01 0x024:MR23 \
        0x028:MR45 0x02c:MR6 0x034:POWER_CTRL 0x038:ARBITRATION \
        0x03c:REQ_LIMIT 0x040:GRANT0 0x044:GRANT1 0x048:GRANT2 \
        0x04c:GRANT3 0x054:ECC_RANGE 0x060:PHY_CTRL0 0x064:PHY_CTRL1 \
        0x068:PHY_CTRL2 0x06c:PHY_CTRL3 0x080:REQ_INPUT 0x084:REQ_HIGH_PRI
    dump_list memory-regs.txt "DDR PHY settings (pinned U-Boot register map)" 0x1e6e0100 \
        0x030:RON_ODT 0x060:DRAM_VREF_RANGE 0x084:TRAINING_TRFC
    dump_list memory-regs.txt "DDR PHY training results (read-only status bank)" 0x1e6e0400 \
        0x000:TRAINING_STATUS 0x030:PU_PD 0x050:GATE_TRAINING \
        0x068:READ_EYE_RISING 0x0c8:READ_EYE_FALLING 0x07c:WRITE_EYE \
        0x088:READ_VREF 0x090:WRITE_VREF
    cfg=$(rd 0x1e6e0004)
    case "$cfg" in *-*) ;; *)
        {
            echo "CONFIG=$cfg"
            echo "capacity_MiB=$((256 << (cfg & 3))) (controller encoding, not a memory test)"
            echo "DDR4=$(((cfg >> 4) & 1)) dual_x8=$(((cfg >> 5) & 1)) ECC=$(((cfg >> 7) & 1))"
            echo "VGA_reserve_MiB=$((8 << ((cfg >> 2) & 3)))"
        } >> "$OUT/memory-config.txt"
        ;;
    esac
    dump_list clock-config.txt "SCU PLLs and SDRAM handshake (raw; strap selects reference clock)" 0x1e6e2000 \
        0x100:HANDSHAKE 0x200:HPLL 0x204:HPLL_EXT 0x210:APLL \
        0x214:APLL_EXT 0x220:MPLL 0x224:MPLL_EXT 0x240:EPLL \
        0x244:EPLL_EXT 0x260:DPLL 0x264:DPLL_EXT
    # Four MACs: never touch poll-demand registers or initiate MDIO transfers.
    for base in 0x1e660000 0x1e680000 0x1e670000 0x1e690000; do
        dump_list mac-regs.txt "FTGMAC100 $base configuration" "$base" \
            0x004:IER 0x008:MAC_MADR 0x00c:MAC_LADR 0x010:HASH0 0x014:HASH1 \
            0x020:TX_RING 0x024:RX_RING 0x02c:HIGH_TX_RING 0x030:INT_TIMER \
            0x034:AUTO_POLL 0x038:DMA_BURST 0x040:REVISION 0x044:FEATURE \
            0x048:TX_ARB 0x04c:RX_BUF_SIZE 0x050:MACCR 0x060:PHYCR 0x068:FLOW_CTRL
    done
    dump_list usb-config.txt "USB vHub global configuration (no endpoint/setup buffers)" 0x1e6a0000 \
        0x000:CTRL 0x004:CONF 0x008:IER 0x010:EP_ACK_IER 0x014:EP_NACK_IER
    dump_list flash-config.txt "SPI2 reserved interface configuration" 0x1e631000 \
        0x000:CONFIG 0x004:CE_CTRL 0x010:CS0_CTRL 0x030:CS0_SEGMENT
    # Offset 0 is function control and offset 4 is clock timing in both
    # AST2600 legacy and new I2C bus register layouts. Skip command/data/status.
    b=0
    while [ "$b" -lt 16 ]; do
        dump_list bus-bindings.txt "I2C$((b + 1)) function/clock (controller index $b)" \
            $((0x1e78a080 + b * 0x80)) 0x000:FUNCTION_CTRL 0x004:CLOCK_TIMING
        b=$((b + 1))
    done
else
    echo "SKIP: AST2600 MMIO unavailable or disabled (-R); use DT/sysfs evidence." \
        >> "$OUT/memory-regs.txt"
    echo "SKIP: AST2600 MMIO unavailable or disabled (-R)." >> "$OUT/mac-regs.txt"
fi

# Inventory includes unbound devices; the old inventory only listed bindings.
# I2C mux links make Linux numbering distinguishable from schematic I2C1..16.
for bus in platform i2c spi mdio_bus i3c peci auxiliary usb; do
    echo "### bus=$bus" >> "$OUT/bus-bindings.txt"
    bcount=0
    for d in /sys/bus/"$bus"/devices/*; do
        [ -d "$d" ] || continue
        bcount=$((bcount + 1))
        binding bus-bindings.txt "$d"
        case "$bus" in
            i2c)
                attr bus-bindings.txt "$d/name"
                for link in "$d/mux_device" "$d"/channel-*; do
                    [ -L "$link" ] && echo "$link -> $(readlink -f "$link")" >> "$OUT/bus-bindings.txt"
                done
                ;;
            i3c)
                attr bus-bindings.txt "$d/pid" "$d/bcr" "$d/dcr" \
                    "$d/dynamic_address" "$d/hdrcap"
                ;;
        esac
    done
    [ "$bcount" -gt 0 ] || echo "SKIP: no devices exposed on bus $bus" >> "$OUT/bus-bindings.txt"
done
for n in /sys/class/net/*; do
    [ -d "$n" ] || continue
    attr network.txt "$n/addr_assign_type" "$n/operstate" "$n/mtu" \
        "$n/duplex" "$n/phydev/phy_id" "$n/phydev/phy_interface" \
        "$n/phydev/attached_dev" "$n"/statistics/*
    if have ethtool && [ "${n##*/}" != lo ]; then
        run network.txt "permanent MAC ${n##*/}" ethtool -P "${n##*/}"
        run network.txt "link statistics ${n##*/}" ethtool -S "${n##*/}"
    fi
done
# No PHY register dump: latched status can be cleared by MDIO reads.
for d in /sys/class/udc/*; do
    binding usb-config.txt "$d"
    attr usb-config.txt "$d/state" "$d/current_speed" "$d/maximum_speed" \
        "$d/is_otg" "$d/function" "$d/uevent"
done
for g in /sys/kernel/config/usb_gadget/*; do
    [ -d "$g" ] || continue
    attr usb-config.txt "$g/UDC" "$g/idVendor" "$g/idProduct" "$g/bcdUSB" \
        "$g/bcdDevice" "$g"/strings/*/manufacturer "$g"/strings/*/product \
        "$g"/strings/*/serialnumber "$g"/configs/*/MaxPower "$g"/configs/*/bmAttributes
    for f in "$g"/functions/*; do
        [ -d "$f" ] || continue
        attr usb-config.txt "$f/protocol" "$f/subclass" "$f/report_length" \
            "$f"/lun.*/file "$f"/lun.*/ro "$f"/lun.*/removable \
            "$f"/lun.*/cdrom "$f"/lun.*/nofua
        if [ -r "$f/report_desc" ]; then
            run usb-config.txt "HID descriptor $f" od -t x1 "$f/report_desc"
        fi
    done
    run usb-config.txt "gadget function bindings $g" ls -l "$g"/configs/*/
done
for d in /sys/bus/usb/devices/*; do
    attr usb-config.txt "$d/idVendor" "$d/idProduct" "$d/product" \
        "$d/manufacturer" "$d/speed" "$d/bConfigurationValue" "$d/bInterfaceClass"
done
for d in /sys/block/nbd*; do
    attr usb-config.txt "$d/size" "$d/pid" "$d/ro" "$d/queue/logical_block_size"
done
for m in /sys/class/mtd/mtd*; do
    case "$m" in *ro) continue ;; esac
    attr flash-config.txt "$m/name" "$m/type" "$m/size" "$m/offset" \
        "$m/erasesize" "$m/writesize" "$m/flags" "$m/ecc_strength" \
        "$m/corrected_bits" "$m/ecc_failures"
done
for d in /sys/bus/spi/devices/*; do
    attr flash-config.txt "$d/modalias" "$d/spi-nor/jedec_id" \
        "$d/spi-nor/partname" "$d/spi-nor/manufacturer"
    if [ -r "$d/spi-nor/sfdp" ]; then
        run flash-config.txt "SFDP $d (first 4 KiB)" sh -c 'head -c 4096 "$1" | od -t x1' sh "$d/spi-nor/sfdp"
    fi
done
attr flash-config.txt /etc/fw_env.config

# Capture installed configuration rather than assuming vendor file names.
# Do not traverse credential directories, full /etc or firmware image payloads.
ATTR_LIMIT=262144
for f in /etc/ceb-gnrd-hardware-contract.yaml \
         /usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml \
         /usr/share/entity-manager/configurations/*.json \
         /usr/share/swampd/*.json /usr/share/phosphor-pid-control/*.json \
         /etc/phosphor-pid-control/*.json /etc/default/obmc-console* \
         /usr/share/x86-power-control/*.json /etc/x86-power-control/*.json \
         /usr/share/phosphor-led-manager/*.json /usr/share/phosphor-led-manager/*.yaml \
         /etc/ntp.conf \
         /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d/*.conf; do
    attr board-config.txt "$f"
done
ATTR_LIMIT=65536
attr board-config.txt /usr/share/ipmi-providers/dev_id.json \
    /usr/share/ipmi-providers/dcmi_sensors.json /usr/share/ipmi-providers/power_reading.json
for w in /sys/class/watchdog/watchdog*; do
    attr watchdog.txt "$w/timeleft" "$w/nowayout" "$w/status" \
        "$w/pretimeout" "$w/pretimeout_governor"
done
for r in /sys/class/rtc/rtc*; do
    attr rtc-values.txt "$r/date" "$r/time" "$r/since_epoch" \
        "$r/max_user_freq" "$r/range" "$r/offset"
done
for p in /var/lib/power-control /var/lib/ceb-gnrd; do
    [ -d "$p" ] && run board-config.txt "state file inventory $p (contents omitted)" ls -l "$p"
done
if have busctl; then
    run board-config.txt "host state" busctl --system get-property \
        xyz.openbmc_project.State.Host /xyz/openbmc_project/state/host0 \
        xyz.openbmc_project.State.Host CurrentHostState
    run board-config.txt "chassis state" busctl --system get-property \
        xyz.openbmc_project.State.Chassis /xyz/openbmc_project/state/chassis0 \
        xyz.openbmc_project.State.Chassis CurrentPowerState
    run board-config.txt "sensor service paths" busctl --system call \
        xyz.openbmc_project.ObjectMapper /xyz/openbmc_project/object_mapper \
        xyz.openbmc_project.ObjectMapper GetSubTreePaths sias \
        /xyz/openbmc_project/sensors 0 1 xyz.openbmc_project.Sensor.Value
fi
have systemctl && run board-config.txt "hardware service status" systemctl --no-pager --full status \
    xyz.openbmc_project.EntityManager.service phosphor-pid-control.service \
    ceb-gnrd-temp-max.service ceb-gnrd-fan-owner.service ceb-gnrd-alert-led.service \
    ceb-gnrd-ncsi.service ceb-gnrd-espi-heartbeat.service obmc-console@ttyS2.service
cat >> "$OUT/hardware-limits.txt" <<'LIMITS'
This is a live snapshot, not a validation or stress test. Values can change
during collection. Compare vendor/new firmware with the same host power state.
Missing attributes/tools and command errors mean unavailable, not zero or PASS.
DT includes disabled and reserved controllers; a declaration is not proof that
a device is fitted. Bus bindings identify controllers and unbound devices.
DDR chip marking, rated speed, PCB routing, voltage, resistor values, strap
resistors and actual clock waveforms cannot be determined reliably by software.
DDR MR values here are controller programming, not a fresh read from the DRAM.
Unknown CPLD/PROM/mux register maps are not probed. No mux or PMBus PAGE writes.
No debugfs mount, driver bind/unbind, network reconfiguration, flash ownership
change, flash payload read, /dev/watchdog open, KCS/SOL FIFO read, HID/NBD read,
USB re-enumeration, PHY page selection, DDR training or memory test is performed.
Direct I2C access can be refused while a driver owns a chip. No -f is used.
I2C scans are opt-in (-s); use -n -R for sysfs/DT-only collection.
Individual commands use timeout when available; kernel uninterruptible I/O
cannot always be cancelled. Old firmware without timeout has no such bound.
Archive can contain serial numbers, MAC/IP addresses and U-Boot environment.
LIMITS

# Embedded snapshot: standalone copies of this script retain the port guide.
# Regenerate this table when meta-ctopai/port_guide.xlsx changes.
cat > "$OUT/port-guide-coverage.txt" <<'PORT_GUIDE'
Source: meta-ctopai/port_guide.xlsx (hardware rows and clarification items)
SHA256: da730d578f72dd8fbe7596fb5fa3590ad373e9636cd10564fe0989967497f6c2
Evidence paths below are snapshot locations, not PASS results. Disabled,
reserved, unbound or unreadable interfaces must be checked in those files.
Ball/net/chip columns describe the guide, not hardware auto-detection.
Row	Category	Interface	SoC pin/block	Ball/address	Board signal	Device	Evidence
5	GPIO/状态线	BMC_SYS_ALERT_LED	GPIOI5	E16	SYS_ALERT_GLED	系统告警 LED	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
6	GPIO/状态线	BMC_FAN_BMC_OVERRIDE_N	GPIOI6	B16	CPLD 风扇 PWM 接管选择 / PBI#	高电平：BMC 接管风扇 PWM；低电平：CPLD 控制	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
7	GPIO/状态线	BMC_HBLED_N / HEARTBEAT	GPIOP7	Y23	CPLD BMC health heartbeat input	BMC 心跳输出，eSPI Peripheral 驱动 SW_READY 后启用	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
8	GPIO/状态线	BMC_BIOS_FLASH_SELECT	GPIOM1	B13	BIOS Flash 控制选择	CPU/BMC SPI1 BIOS Flash 切换	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
9	GPIO/状态线	BMC_POWER_BUTTON_INPUT	GPIOM2	A12	Power button 输入	检测机箱电源按键	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
10	GPIO/状态线	BMC_BIOS_BOOT_OK	GPIOM7	D13	BIOS POST/启动完成	检测 BIOS boot OK	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
11	GPIO/状态线	PCB_VER0	GPIOS4	R26	PCB_VER0 strap	主板硬件版本 bit0	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
12	GPIO/状态线	PCB_VER1	GPIOS5	P24	PCB_VER1 strap	主板硬件版本 bit1	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
13	GPIO/状态线	PCB_VER2	GPIOS6	P23	PCB_VER2 strap	主板硬件版本 bit2	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
14	GPIO/状态线	CFG_VER0	GPIOS7	T24	配置版本 strap	额外配置 strap；合同标记非 PCB revision	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
15	GPIO/状态线	BMC_UID_BUTTON_N	GPIOV0	AB15	UID button 输入	机箱 UID 按键	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
16	GPIO/状态线	BMC_UID_LED	GPIOV1	AF14	UID LED 输出	前面板 UID 指示灯	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
17	GPIO/状态线	BMC_CPU_POWER_BUTTON	GPIOV2	AD14	CPU Power button 控制	向 CPU/CPLD 输出开关机脉冲	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
18	GPIO/状态线	BMC_CPU_RESET	GPIOV3	AC15	CPU Reset 控制	向 CPU 输出 reset	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
19	GPIO/状态线	BMC_CPU_PWRGD	GPIOV4	AE15	CPU PWRGD 输入	判断 CPU/主机上电状态	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
20	GPIO/状态线	CHASI# chassis intrusion	AST2600 dedicated CHASI# input (non-GPIO)	AB21	机箱开盖检测输入	读取 AST2600 chassis intrusion latch	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
21	GPIO/状态线	BMC_FRU_WP	GPIOG6_TXD9_SD2CD#_SALT15	D21	BMC_FRU_WP	FM24C08D；24C02 封装	gpio-pins.txt gpio-regs.txt gpio-kernel.txt scu-regs.txt leds.txt board-config.txt
22	ADC 电压	ADC0 channel 0	ADC0 analog pad	AD20	P12V_SYS_ADC0	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
23	ADC 电压	ADC0 channel 1	ADC1 analog pad	AC18	P5V0_SYS_ADC1	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
24	ADC 电压	ADC0 channel 2	ADC2 analog pad	AE19	P3V3_SYS_ADC2	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
25	ADC 电压	ADC0 channel 3	ADC3 analog pad	AD19	PVCCIN_CPU_ADC3	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
26	ADC 电压	ADC0 channel 4	ADC4 analog pad	AC19	PVNN_NAC_CPU_ADC4	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
27	ADC 电压	ADC0 channel 5	ADC5 analog pad	AB19	PVCCD0_HV_CPU_ADC5	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
28	ADC 电压	ADC0 channel 6	ADC6 analog pad	AB18	PVCCINF_CPU_ADC6	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
29	ADC 电压	ADC0 channel 7	ADC7 analog pad	AE18	PVNN_MAIN_CPU_ADC7	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
30	ADC 电压	ADC1 channel 0	ADC8 analog pad	AB16	PVCCFA_EHV_CPU_ADC8	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
31	ADC 电压	ADC1 channel 1	ADC9 analog pad	AA17	PVCCD1_HV_CPU_ADC9	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
32	ADC 电压	ADC1 channel 2	ADC10 analog pad	AB17	PVCCINF_EHV_FIVRA_CPU_ADC10	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
33	ADC 电压	ADC1 channel 3	ADC11 analog pad	AE16	P3V3_STBY_ADC11	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
34	ADC 电压	ADC1 channel 4	ADC12 analog pad	AC16	P1V8_STBY_ADC12	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
35	ADC 电压	ADC1 channel 5	ADC13 analog pad	AA16	P1V2_STBY_ADC13	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
36	ADC 电压	ADC1 channel 6	ADC14 analog pad	AD16	P1V0_STBY_ADC14	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
37	ADC 电压	ADC1 channel 7	ADC15 analog pad	AC17	D3V0_BAT0_ADC15	板上分压电阻/电源 rail	hwmon-values.txt iio-values.txt block-regs.txt board-config.txt
38	风扇 PWM	PWM0 / BMC_FAN0_PWM	GPIOO0	AD26	BMC_FAN0_PWM	CPLD PWM 通路 -> 风扇 FAN0	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
39	风扇 TACH	TACH0 / SYS_FAN0_TACH	GPIOQ0	AA25	SYS_FAN0_TACH	风扇插座 FAN0	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
40	风扇 PWM	PWM1 / BMC_FAN1_PWM	GPIOO1	AD22	BMC_FAN1_PWM	CPLD PWM 通路 -> 风扇 FAN1	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
41	风扇 TACH	TACH1 / SYS_FAN1_TACH	GPIOQ1	AB25	SYS_FAN1_TACH	风扇插座 FAN1	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
42	风扇 PWM	PWM2 / BMC_FAN2_PWM	GPIOO2	AD23	BMC_FAN2_PWM	CPLD PWM 通路 -> 风扇 FAN2	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
43	风扇 TACH	TACH2 / SYS_FAN2_TACH	GPIOQ2	Y24	SYS_FAN2_TACH	风扇插座 FAN2	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
44	风扇 PWM	PWM3 / BMC_FAN3_PWM	GPIOO3	AD24	BMC_FAN3_PWM	CPLD PWM 通路 -> 风扇 FAN3	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
45	风扇 TACH	TACH3 / SYS_FAN3_TACH	GPIOQ3	AB26	SYS_FAN3_TACH	风扇插座 FAN3	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
46	风扇 PWM	PWM4 / BMC_FAN4_PWM	GPIOO4	AD25	BMC_FAN4_PWM	CPLD PWM 通路 -> 风扇 FAN4	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
47	风扇 TACH	TACH4 / SYS_FAN4_TACH	GPIOQ4	Y26	SYS_FAN4_TACH	风扇插座 FAN4	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
48	风扇 PWM	PWM5 / BMC_FAN5_PWM	GPIOO5	AC22	BMC_FAN5_PWM	CPLD PWM 通路 -> 风扇 FAN5	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
49	风扇 TACH	TACH5 / SYS_FAN5_TACH	GPIOQ5	AC26	SYS_FAN5_TACH	风扇插座 FAN5	hwmon-values.txt block-regs.txt gpio-pins.txt board-config.txt
50	I2C	I2C1 SCL1 (SCL)	GPIOJ0	B20	BMC_SLOT1_I2C1 / AST I2C1	PCIe x8 slot 1	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
51	I2C	I2C1 SDA1 (SDA)	GPIOJ1	A20	BMC_SLOT1_I2C1 / AST I2C1	PCIe x8 slot 1	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
52	I2C	I2C2 SCL2 (SCL)	GPIOJ2	E19	BMC_SLOT3_I2C2 / AST I2C2	PCIe x16 slot 3	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
53	I2C	I2C2 SDA2 (SDA)	GPIOJ3	D20	BMC_SLOT3_I2C2 / AST I2C2	PCIe x16 slot 3	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
54	I2C	I2C3 SCL3 (SCL)	GPIOJ4	C19	BMC_SLOT4_I2C3 / AST I2C3	PCIe x8 slot 4	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
55	I2C	I2C3 SDA3 (SDA)	GPIOJ5	A19	BMC_SLOT4_I2C3 / AST I2C3	PCIe x8 slot 4	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
56	I2C	I2C4 SCL4 (SCL)	GPIOJ6	C20	BMC_SLOT5_I2C4 / AST I2C4	PCIe x8 slot 5	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
57	I2C	I2C4 SDA4 (SDA)	GPIOJ7	D19	BMC_SLOT5_I2C4 / AST I2C4	PCIe x8 slot 5	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
58	I2C	I2C5 SCL5 (SCL)	GPIOK0	A11	BMC_SLOT6_I2C5 / AST I2C5	PCIe x16 slot 6	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
59	I2C	I2C5 SDA5 (SDA)	GPIOK1	C11	BMC_SLOT6_I2C5 / AST I2C5	PCIe x16 slot 6	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
60	I2C	I2C6 SCL6 (SCL)	GPIOK2	D12	BMC_SLOT7_I2C6 / AST I2C6	PCIe x8 slot 7	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
61	I2C	I2C6 SDA6 (SDA)	GPIOK3	E13	BMC_SLOT7_I2C6 / AST I2C6	PCIe x8 slot 7	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
62	I2C	I2C7 SCL7 (SCL)	GPIOK4	D11	BMC_SENSOR_I2C7 / AST I2C7	4 x NST175H-QSPR	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
63	I2C	I2C7 SDA7 (SDA)	GPIOK5	E11	BMC_SENSOR_I2C7 / AST I2C7	4 x NST175H-QSPR	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
64	I2C	I2C8 SCL8 (SCL)	GPIOK6	F13	BMC_CPRS_I2C8 / AST I2C8	CRPS PMBus PSU	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
65	I2C	I2C8 SDA8 (SDA)	GPIOK7	E12	BMC_CPRS_I2C8 / AST I2C8	CRPS PMBus PSU	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
66	I2C	I2C9 SCL9 (SCL)	GPIOL0	D15	BMC_CPLD_I2C9 / AST I2C9	CPLD (reserved)	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
67	I2C	I2C9 SDA9 (SDA)	GPIOL1	A14	BMC_CPLD_I2C9 / AST I2C9	CPLD (reserved)	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
68	I2C	I2C10 SCL10 (SCL)	GPIOL2	E15	BMC_RTC_I2C10 / AST I2C10	NCT3015Y-R	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
69	I2C	I2C10 SDA10 (SDA)	GPIOL3	A13	BMC_RTC_I2C10 / AST I2C10	NCT3015Y-R	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
70	I2C	I2C11 SCL11 (SCL)	GPIOA0	M24	BMC_FRU_I2C11 / AST I2C11	FM24C08D; 8 Kbit / 1 KiB; 24C02 package outline	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
71	I2C	I2C11 SDA11 (SDA)	GPIOA1	M25	BMC_FRU_I2C11 / AST I2C11	FM24C08D; 8 Kbit / 1 KiB; 24C02 package outline	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
72	I2C	I2C12 SCL12 (SCL)	GPIOA2	L26	BMC_TCA9546_I2C12 / AST I2C12	TCA9546A mux（I2C12 预留）	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
73	I2C	I2C12 SDA12 (SDA)	GPIOA3	K24	BMC_TCA9546_I2C12 / AST I2C12	TCA9546A mux（I2C12 预留）	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
74	I2C	I2C13 SCL13 (SCL)	GPIOA4	K26	BMC_MCIO_I2C13 / AST I2C13	MCIO x8 connector	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
75	I2C	I2C13 SDA13 (SDA)	GPIOA5	L24	BMC_MCIO_I2C13 / AST I2C13	MCIO x8 connector	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
76	I2C	I2C14 SCL14 (SCL)	GPIOA6	L23	BMC_MCIO_I2C14 / AST I2C14	Reserved / MCIO	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
77	I2C	I2C14 SDA14 (SDA)	GPIOA7	K25	BMC_MCIO_I2C14 / AST I2C14	Reserved / MCIO	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
78	I2C	I2C15 SCL15 (SCL)	GPIOH4	D18	BMC_PROM_SCL/SDA / AST I2C15	CPU SMBUS_HOST PROM	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
79	I2C	I2C15 SDA15 (SDA)	GPIOH5	B17	BMC_PROM_SCL/SDA / AST I2C15	CPU SMBUS_HOST PROM	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
80	I2C	I2C16 SCL16 (SCL)	GPIOH6	C17	MIPI60_I2C / AST I2C16	MIPI60 connector	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
81	I2C	I2C16 SDA16 (SDA)	GPIOH7	E18	MIPI60_I2C / AST I2C16	MIPI60 connector	i2c-devices.txt bus-bindings.txt chips.txt dt-properties.txt i2c-scan.txt(-s)
82	eSPI Peripheral	LAD0 / ESPID0	GPIOW0	AB7	CPU_ESPI_IO0	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
83	eSPI Peripheral	LAD1 / ESPID1	GPIOW1	AB8	CPU_ESPI_IO1	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
84	eSPI Peripheral	LAD2 / ESPID2	GPIOW2	AC8	CPU_ESPI_IO2	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
85	eSPI Peripheral	LAD3 / ESPID3	GPIOW3	AC7	CPU_ESPI_IO3	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
86	eSPI Peripheral	LCLK / ESPICK	GPIOW4	AE7	CPU_ESPI_CLK	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
87	eSPI Peripheral	LFRAME# / ESPICS#	GPIOW5	AF7	CPU_ESPI_CS0	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
88	eSPI Peripheral	LSIRQ# / ESPIALT#	GPIOW6	AD7	CPU_ESPI_ALT	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
89	eSPI Peripheral	LPCRST# / ESPIRST#	GPIOW7	AD8	CPU_ESPI_RSTN	Intel Xeon 6 CPU	espi-regs.txt lpc-regs.txt bus-bindings.txt scu-regs.txt
90	UART / SOL	TXD3	GPIOL4	C15	BMC_CPU_SOL_TXD	CPU debug/console UART	serial.txt console-vga.txt vuart-regs.txt scu-regs.txt
91	UART / SOL	RXD3	GPIOL5	F15	BMC_CPU_SOL_RXD	CPU debug/console UART	serial.txt console-vga.txt vuart-regs.txt scu-regs.txt
92	UART / Debug	TXD5	UART5 TXD5	C8	BMC_UART5_DEBUG_TXD	BMC debug header / serial console	serial.txt console-vga.txt vuart-regs.txt scu-regs.txt
93	UART / Debug	RXD5	UART5 RXD5	D8	BMC_UART5_DEBUG_RXD	BMC debug header / serial console	serial.txt console-vga.txt vuart-regs.txt scu-regs.txt
94	VGA / KVM	VGAHS	GPIOL6	B14	BMC_VGA_HSYNC	CPU console VGA display output	console-vga.txt memory-config.txt block-regs.txt clock-config.txt
95	VGA / KVM	VGAVS	GPIOL7	C14	BMC_VGA_VSYNC	CPU console VGA display output	console-vga.txt memory-config.txt block-regs.txt clock-config.txt
96	VGA / KVM	DDCCLK	DDCCLK fixed VGA pad	B8	BMC_VGA_DDCCLK	Display DDC clock	console-vga.txt memory-config.txt block-regs.txt clock-config.txt
97	VGA / KVM	DDCDATA	DDCDAT fixed VGA pad	A8	BMC_VGA_DDCDATA	Display DDC data	console-vga.txt memory-config.txt block-regs.txt clock-config.txt
98	USB / KVM HID	USB2ADDP	USB2A	A4	VL805_USB2_P4_DP	VL805 USB port 4 / Host USB	usb-config.txt bus-bindings.txt scu-regs.txt
99	USB / KVM HID	USB2ADDN	USB2A	B4	VL805_USB2_P4_DM	VL805 USB port 4 / Host USB	usb-config.txt bus-bindings.txt scu-regs.txt
100	Ethernet MAC2	RGMII2RXCK	GPIO18C2	D2	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
101	Ethernet MAC2	RGMII2RXCTL	GPIO18C3	E3	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
102	Ethernet MAC2	RGMII2RXD0	GPIO18C4	D1	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
103	Ethernet MAC2	RGMII2RXD1	GPIO18C5	F4	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
104	Ethernet MAC2	RGMII2RXD2	GPIO18C6	E2	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
105	Ethernet MAC2	RGMII2RXD3	GPIO18C7	E1	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
106	Ethernet MAC2	RGMII2TXCK	GPIO18B4	D4	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
107	Ethernet MAC2	RGMII2TXCTL	GPIO18B5	C2	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
108	Ethernet MAC2	RGMII2TXD0	GPIO18B6	C1	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
109	Ethernet MAC2	RGMII2TXD1	GPIO18B7	D3	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
110	Ethernet MAC2	RGMII2TXD2	GPIO18C0	E4	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
111	Ethernet MAC2	RGMII2TXD3	GPIO18C1	F5	Physical MAC2 / RGMII2 / 1.8 V I/O	RTL8211FS-CG PHY / 独立 RJ45	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
112	Ethernet PHY 管理	MDC2	GPIOB4	J23	Physical MAC2 PHY management	RTL8211FS-CG PHY	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
113	Ethernet PHY 管理	MDIO2	GPIOB5	G26	Physical MAC2 PHY management	RTL8211FS-CG PHY	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
114	Ethernet MAC3 / NC-SI	RGMII3TXCTL / NCSI TXEN	GPIOC1	J22	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
115	Ethernet MAC3 / NC-SI	RGMII3TXD0 / NCSI TXD0	GPIOC2	H22	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
116	Ethernet MAC3 / NC-SI	RGMII3TXD1 / NCSI TXD1	GPIOC3	H23	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
117	Ethernet MAC3 / NC-SI	RGMII3RXCK / NCSI RXCLK	GPIOC6	G23	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
118	Ethernet MAC3 / NC-SI	RGMII3RXD0 / NCSI RXD0	GPIOD0	F23	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
119	Ethernet MAC3 / NC-SI	RGMII3RXD1 / NCSI RXD1	GPIOD1	F26	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
120	Ethernet MAC3 / NC-SI	RGMII3RXD2 / NCSI CRS_DV	GPIOD2	F25	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
121	Ethernet MAC3 / NC-SI	RGMII3RXD3 / NCSI RXER	GPIOD3	E26	Physical MAC3 / NCSI3 pads	Intel E810 NC-SI interface	network.txt net-layout.txt mac-regs.txt clock-config.txt chips.txt
122	SPI1 / BIOS Flash	SPI1CK	GPIOZ3	AB11	AST2600 SPI1 CS0	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
123	SPI1 / BIOS Flash	SPI1MOSI	GPIOZ4	AC11	AST2600 SPI1 CS0	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
124	SPI1 / BIOS Flash	SPI1MISO	GPIOZ5	AA11	AST2600 SPI1 CS0	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
125	SPI1 / BIOS Flash	SPI1DQ2 (x1 模式未用)	GPIOZ6 / SPI1DQ2	AD11	STARP_BMC_GPIOZ6 (原理图网络)	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
126	SPI1 / BIOS Flash	SPI1DQ3 (x1 模式未用)	GPIOZ7 / SPI1DQ3	AF10	STARP_BMC_GPIOZ7 (原理图网络)	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
127	SPI1 / BIOS Flash	SPI1CS0#	Dedicated SPI1 CS0 pad	AD13	BMC_SPI1_CS0	Macronix MX25U51245GMI00, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
128	Firmware SPI / BMC Flash	FWSPICS0#	Dedicated Firmware SPI CS0	AB14	BMC_FLASH_SPI_CS0	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
129	Firmware SPI / BMC Flash	FWSPICK	Dedicated Firmware SPI clock	AF13	BMC_FLASH_SPI_SCK	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
130	Firmware SPI / BMC Flash	FWSPIMOSI	Dedicated Firmware SPI MOSI	AC14	BMC_FLASH_SPI_MOSI	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
131	Firmware SPI / BMC Flash	FWSPIMISO	Dedicated Firmware SPI MISO	AB13	BMC_FLASH_SPI_MISO	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
132	Firmware SPI / BMC Flash	FWSPIQ2	GPIOY4 / Firmware SPI DQ2	AE12	BMC_FLASH_SPI_DQ2	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
133	Firmware SPI / BMC Flash	FWSPIQ3	GPIOY5 / Firmware SPI DQ3	AF12	BMC_FLASH_SPI_DQ3	Winbond W25Q512JVFIQ, 64 MiB	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
134	SPI2	SPI2 / CS0	SPI2 controller	AE8 (CS0) / AF8 (SCK) / AB9 (MOSI) / AD9 (MISO) / AF9 (DQ2) / AB10 (DQ3)	FLASH_SPI2_SCK / MOSI / MISO / DQ2 / DQ3（预留，未使用）	无（本板未使用）	flash-config.txt mtd.txt block-regs.txt gpio-pins.txt scu-regs.txt
135	PECI	PECI0	PECI controller	AT29	BMC_CPU_PECI	Intel Xeon 6 CPU	bus-bindings.txt hwmon-layout.txt hwmon-values.txt block-regs.txt dt-properties.txt
136	I3C	AST2600 I3C1-4（仅 I3C3 启用）	I3C master controllers	I3C1/2/4: 未启用；I3C3: SoC pinctrl group	I3C1/2 未启用；I3C3SCL_FSI1CLK / I3C3SDA_FSI1DATA 接 CPU I3C_MNG_SCL/SDA；I3C4 未启用	Xeon 6 CPU management interface (I3C3); no I3C DIMM temperature devices	bus-bindings.txt hwmon-layout.txt hwmon-values.txt block-regs.txt dt-properties.txt
139	待澄清	D3V0_BAT0 分压	ADC1 channel 7 / ADC15	AC17		EE / 硬件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
140	待澄清	BIOS 与 BMC 的 eSPI SIO 访问	eSPI Peripheral 通道 / 端口 0x2E 0x2F	CPU_ESPI_IO0-3、CLK、CS0、ALERT、RSTN		BIOS / 软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
141	待澄清	管理网口 PHY	MAC2 / RGMII2 / RTL8211FS-CG	MDIO 地址、复位、延时		EE / 硬件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
142	待澄清	RTC 驱动兼容性	I2C10 / 0x6F	NCT3015Y-R		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
143	待澄清	告警 LED 服务	BMC_SYS_ALERT_LED	GPIOI5		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
144	待澄清	风扇控制配置	6 路风扇 / 网页 Fan control	PWM0-5、TACH0-5		软件 / 硬件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
145	待澄清	PSU 在位检测	I2C8 / 0x58 0x59 0x5A	CRPS PMBus		软件 / 硬件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
146	待澄清	mc info 与 BMC 状态	IPMI Get Device ID	Device Available / Firmware Revision		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
147	待澄清	IPMI 传感器暴露	ipmitool sensor / Web 传感器	ADC、温度、风扇、CPU、DIMM		产品 / 软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
148	待澄清	构建与验证状态	内核 / U-Boot / 网页 / IPMI / 电源控制	—		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
149	待澄清	U-Boot 网络启动与 netupdate	bootcmd / netupdate / serverip	AST2600 MAC2 + RTL8211FS（U-Boot 里只用该口）		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
150	待澄清	主机 KCS 通道	kcs3 / ipmi-kcs3	AST2600 LPC KCS3，I/O 端口 0xCA2		硬件 + 软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
151	待澄清	NC-SI 网口（eth1）拉起与重试	eth1 / ceb-gnrd-ncsi	AST2600 MAC3 + Intel E810（无待机供电）		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
152	待澄清	SEL 记录与 rollover	ipmi_sel / sel-logger	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
153	待澄清	网页补丁和 bmcweb 选项	webui 0009-0011；redfish-dump-log	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
154	待澄清	DCMI 与 IPMI 常规命令	dcmi / power_reading.json / dcmi_sensors.json	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
155	待澄清	风扇 OEM 命令（netfn 0x30）	ceb-gnrd-ipmi-fan / fan_oem.cpp / ceb-gnrd-fan-settings.py	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
156	待澄清	风扇写 Entity-Manager 报 InvalidArgs（已解决）	ceb-gnrd-fan-settings.py / ceb-gnrd.json（Pid 改名 Fan<n> Control）	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
157	待澄清	开机后一分钟内 ipmitool sensor 只有 2 个（已解决）	phosphor-ipmi-host drop-in 10-ceb-gnrd-wait-sensors.conf	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
158	待澄清	Redfish FirmwareVersion 为空 / 网页 BMC 版本 --	bmcweb_%.bbappend	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
159	待澄清	BMC 转储列表为空（已解决）	phosphor-debug-collector / bmcweb redfish-dump-log	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
160	待澄清	SD/eMMC 禁用与 BMC 硬件看门狗	aspeed-ceb-gnrd.dts / ast2600-ceb-gnrd.dts（U-Boot）/ espi-peci.cfg	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
161	待澄清	板级自检脚本 ceb-gnrd-check	recipes-phosphor/utils/ceb-gnrd-check.bb	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
162	待澄清	策略页与固件页精简	0010、0012 网页补丁	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
163	待澄清	与 OpenBMC 惯例对齐的改动	conf/machine/ceb-gnrd.conf；ctopai-openbmc.conf；补丁文件	BMC 软件		软件	ceb-gnrd-checklist.txt board-config.txt hardware-limits.txt (requires item-specific verification)
Supplement: DDR -> memory-config.txt memory-regs.txt clock-config.txt
Supplement: reset reason -> memory-config.txt scu-regs.txt
Supplement: NBD/virtual media -> usb-config.txt journal.txt
PORT_GUIDE

# ---------------------------------------------------------------- archive
rm -f "$NAMES"
if ! (cd "$OUTBASE" && tar -czf "$NAME.tar.gz" "$NAME" 2>>"$LOG"); then
    say "ERROR: archive creation failed; raw output remains in $OUT"
    exit 1
fi
say ""
say "done: $OUTBASE/$NAME.tar.gz  ($(du -k "$OUTBASE/$NAME.tar.gz" 2>/dev/null | cut -f1) KiB)"
say "copy it off the BMC (scp) and compare with the dump of the other firmware:"
say "  sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz"

# Console output for copy and paste: the checklist always, every file with -a.
if [ "$ALL" = 1 ]; then
    for t in "$OUT"/*.txt; do
        case "$t" in */dt-properties.txt|*/dmesg.txt|*/journal.txt) continue ;; esac
        echo
        echo "################################################ ${t##*/}"
        cat "$t"
    done
    echo
    echo "(dt-properties.txt, dmesg.txt and journal.txt are only in the archive)"
fi
echo
echo "################################################ ceb-gnrd-checklist.txt"
cat "$CK"
