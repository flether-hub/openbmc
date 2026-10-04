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
        dev-nodes.txt console-vga.txt chips.txt ceb-gnrd-checklist.txt
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
OUTBASE=/tmp
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SCAN=1 ;;
        -n) PROBE=0 ;;
        -o) shift; OUTBASE=${1:?-o needs a directory} ;;
        -h|--help) sed -n '2,/^PATH=/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown option $1 (see -h)" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$OUTBASE" && OUTBASE=$(cd "$OUTBASE" && pwd) || exit 1
HOST=$(hostname 2>/dev/null || echo bmc)
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
NAME=bmc-hw-$HOST-$STAMP
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
        echo
    } >> "$OUT/$file"
}

# show FILE PATH... : append "path: content" of small sysfs/proc files.
show() {
    file=$1; shift
    for p in "$@"; do
        [ -r "$p" ] || continue
        v=$(tr '\0' ' ' < "$p" 2>/dev/null | head -c 2000)
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
have journalctl && run journal.txt "journal (this boot)" journalctl -b --no-pager
[ -r /var/log/messages ] && run journal.txt "/var/log/messages" tail -n 3000 /var/log/messages

# ---------------------------------------------------------------- 2. device tree
say "[2/15] device tree"
if [ -r /sys/firmware/fdt ]; then
    cp /sys/firmware/fdt "$OUT/device-tree.dtb" 2>/dev/null &&
        echo "raw blob saved: decompile on the PC with  dtc -I dtb -O dts device-tree.dtb" >> "$OUT/system.txt"
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
if [ -e /dev/mem ]; then
    if have devmem; then DEVMEM=devmem
    elif have busybox && busybox devmem 0x1e6e2004 >/dev/null 2>&1; then DEVMEM="busybox devmem"
    fi
fi
rd() {
    # rd ADDR -> 0x%08x value or "--------"
    v=$($DEVMEM "$(printf '0x%08x' "$1")" 32 2>/dev/null)
    [ -n "$v" ] && printf '0x%08x' "$v" || echo "----------"
}
dump_range() {
    # dump_range FILE TITLE BASE FIRST LAST : 32-bit registers BASE+FIRST..BASE+LAST
    file=$1 title=$2 base=$3 off=$4 last=$5
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
    say "[4-7/15] skipped: no /dev/mem or devmem on this firmware (registers not read)"
    echo "devmem / /dev/mem not available: register dump skipped" > "$OUT/scu-regs.txt"
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
    dd if="$e" of="$OUT/eeprom-$d.bin" bs=1024 count=8 2>/dev/null
    if have hexdump; then
        hexdump -C "$OUT/eeprom-$d.bin" > "$OUT/eeprom-$d.txt"
    elif have od; then
        od -A x -t x1z "$OUT/eeprom-$d.bin" > "$OUT/eeprom-$d.txt" 2>/dev/null
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
        [ -n "$fds" ] && echo "pid ${p#/proc/} $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | head -c 150): $fds"
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
if [ "$PROBE" = 1 ] && have i2cget; then
    B6=$(busof 6); B7=$(busof 7); B9=$(busof 9); B10=$(busof 10)
    {
        echo "### chip identification over I2C (controller -> bus here: I2C7=i2c-$B6, I2C8=i2c-$B7, I2C10=i2c-$B9, I2C11=i2c-$B10)"
        echo "# temperature sensors (NST175 / LM75 family): TEMP reg0, CONF reg1, THYST reg2, TOS reg3"
        echo "# an LM75-compatible chip at power-on has THYST 75 C and TOS 80 C"
        for a in 0x48 0x49 0x4a 0x4b; do
            t=$(i2cget -y "$B6" $a 0x00 w 2>/dev/null)
            if [ -z "$t" ]; then echo "i2c-$B6 $a: no answer"; continue; fi
            c=$(i2cget -y "$B6" $a 0x01 b 2>/dev/null)
            h=$(i2cget -y "$B6" $a 0x02 w 2>/dev/null)
            o=$(i2cget -y "$B6" $a 0x03 w 2>/dev/null)
            msb=$(( t & 0xff )); [ "$msb" -ge 128 ] && msb=$((msb - 256))
            half=$(( (t >> 15) & 1 ))
            echo "i2c-$B6 $a: temp=$msb.$((half * 5)) C conf=$c thyst=$(( h & 0xff )) C tos=$(( o & 0xff )) C (raw $t $h $o)"
        done
        echo
        echo "# RTC NCT3015Y / NCT3018Y at 0x6f: registers 0x00-0x1f"
        r=""
        i=0
        while [ $i -lt 32 ]; do
            v=$(i2cget -y "$B9" 0x6f $i b 2>/dev/null) || { r="no answer"; break; }
            r="$r ${v#0x}"
            i=$((i + 1))
        done
        echo "i2c-$B9 0x6f:$r"
        echo
        echo "# FRU EEPROM: a 24C08 (1 KiB) answers at 0x50-0x53, a 24C02 only at 0x50"
        for a in 0x50 0x51 0x52 0x53 0x54 0x55 0x56 0x57; do
            v=$(i2cget -y "$B10" $a 0x00 b 2>/dev/null) && echo "i2c-$B10 $a: answers (byte0=$v)"
        done
        if [ ! -e "/sys/bus/i2c/devices/$(printf '%s-%04x' "$B10" 0x50)/eeprom" ]; then
            r=""; i=0
            while [ $i -lt 16 ]; do
                v=$(i2cget -y "$B10" 0x50 $i b 2>/dev/null) || break
                r="$r ${v#0x}"; i=$((i + 1))
            done
            echo "i2c-$B10 0x50 first 16 bytes:$r  (FRU common header starts with 01)"
        fi
        echo
        echo "# PMBus PSUs: PMBUS_REVISION 0x98, MFR_ID 0x99, MFR_MODEL 0x9a, MFR_REVISION 0x9b"
        for a in 0x58 0x59 0x5a; do
            rev=$(i2cget -y "$B7" $a 0x98 b 2>/dev/null)
            if [ -z "$rev" ]; then echo "i2c-$B7 $a: no answer (slot empty?)"; continue; fi
            id=$(i2cget -y "$B7" $a 0x99 s 2>/dev/null)
            md=$(i2cget -y "$B7" $a 0x9a s 2>/dev/null)
            mr=$(i2cget -y "$B7" $a 0x9b s 2>/dev/null)
            echo "i2c-$B7 $a: pmbus_rev=$rev MFR_ID='$(hex2ascii $id)' MFR_MODEL='$(hex2ascii $md)' MFR_REVISION='$(hex2ascii $mr)'"
        done
        echo
    } >> "$OUT/chips.txt" 2>&1
fi
# PHY identity through the MII registers (read-only ioctl), for every interface.
if have mii-tool; then
    for n in /sys/class/net/eth*; do
        [ -e "$n" ] || continue
        run chips.txt "MII registers of ${n##*/} (vendor OUI / model / revision)" mii-tool -v "${n##*/}"
    done
fi

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

sect "host interfaces (eSPI / KCS / POST code / host serial console)"
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
ck "host console source: $(grep -E '^pid ' "$OUT/serial.txt" 2>/dev/null | head -n 3 | tr '\n' ';')"

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

# ---------------------------------------------------------------- archive
rm -f "$NAMES"
cd "$OUTBASE" && tar -czf "$NAME.tar.gz" "$NAME" 2>>"$LOG"
say ""
say "done: $OUTBASE/$NAME.tar.gz  ($(du -k "$OUTBASE/$NAME.tar.gz" 2>/dev/null | cut -f1) KiB)"
say "copy it off the BMC (scp) and compare with the dump of the other firmware:"
say "  sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz"
