#!/bin/sh
# bmc-hw-dump.sh - read-only dump of how a running AST2600 BMC firmware uses the
# board hardware, so the vendor firmware and the new ceb-gnrd firmware can be
# compared before the new image is deployed.
#
# Usage
#   On the BMC (old vendor firmware first, later the new firmware):
#     sh bmc-hw-dump.sh            dump into /tmp/bmc-hw-<host>-<time>.tar.gz
#     sh bmc-hw-dump.sh -s         also scan the I2C buses (i2cdetect -r, see below)
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
#   USB device, video, PECI, kernel log and process list, ipmitool output.
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
        dev-nodes.txt
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
OUTBASE=/tmp
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SCAN=1 ;;
        -o) shift; OUTBASE=${1:?-o needs a directory} ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
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
say "[1/14] system information"
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
say "[2/14] device tree"
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
say "[3/14] GPIO"
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
    say "[4/14] SCU (chip id, straps, pin mux, clock delays)"
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
    say "[5/14] GPIO controller registers (direction and value of every pin)"
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
    say "[6/14] eSPI, LPC (KCS / snoop / SuperIO), VUART registers"
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
    say "[7/14] PWM/tach, ADC, watchdog, SPI controller registers"
    dump_range block-regs.txt "PWM / tach 0x1e610000" 0x1e610000 0x000 0x0fc
    dump_range block-regs.txt "ADC0 0x1e6e9000" 0x1e6e9000 0x000 0x0cc
    dump_range block-regs.txt "ADC1 0x1e6e9100" 0x1e6e9100 0x000 0x0cc
    dump_range block-regs.txt "WDT1..4 0x1e785000" 0x1e785000 0x000 0x0fc
    dump_range block-regs.txt "FMC (BMC flash) 0x1e620000" 0x1e620000 0x000 0x0fc
    dump_range block-regs.txt "SPI1 (host BIOS flash) 0x1e630000" 0x1e630000 0x000 0x0fc
else
    say "[4-7/14] skipped: no /dev/mem or devmem on this firmware (registers not read)"
    echo "devmem / /dev/mem not available: register dump skipped" > "$OUT/scu-regs.txt"
fi

# ---------------------------------------------------------------- 8. I2C
say "[8/14] I2C buses and devices"
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
say "[9/14] hwmon and ADC"
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
say "[10/14] UARTs, VUART and host console"
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
say "[11/14] network (MAC, PHY address, NC-SI)"
{
    for n in /sys/class/net/*; do
        i=${n##*/}
        [ "$i" = lo ] && continue
        phy=$(readlink "$n/phydev" 2>/dev/null | sed 's|.*/||')
        echo "$i dev=$(readlink -f "$n/device" 2>/dev/null | sed 's|.*/||') phy=${phy:-<none, NC-SI or fixed>} carrier=$(cat "$n/carrier" 2>/dev/null) speed=$(cat "$n/speed" 2>/dev/null)"
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
say "[12/14] SPI flash partitions"
run mtd.txt "mtd partitions" cat /proc/mtd
for m in /sys/class/mtd/mtd[0-9]*; do
    [ -d "$m" ] || continue
    case "$m" in *ro) continue ;; esac
    echo "${m##*/} name=$(cat "$m/name" 2>/dev/null) size=$(cat "$m/size" 2>/dev/null) parent=$(readlink -f "$m/device" 2>/dev/null | sed 's|^/sys/devices/||')" >> "$OUT/mtd.txt"
done
grep -i -E 'spi-nor|spi_nor|mtd|fmc|jedec' "$OUT/dmesg.txt" >> "$OUT/mtd.txt" 2>/dev/null

# ---------------------------------------------------------------- 13. LEDs, watchdog, RTC, other devices
say "[13/14] LEDs, watchdog, RTC, USB, video, PECI, device nodes"
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
} > "$OUT/dev-nodes.txt"

# ---------------------------------------------------------------- 14. IPMI
say "[14/14] IPMI (if ipmitool exists on this firmware)"
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

# ---------------------------------------------------------------- archive
rm -f "$NAMES"
cd "$OUTBASE" && tar -czf "$NAME.tar.gz" "$NAME" 2>>"$LOG"
say ""
say "done: $OUTBASE/$NAME.tar.gz  ($(du -k "$OUTBASE/$NAME.tar.gz" 2>/dev/null | cut -f1) KiB)"
say "copy it off the BMC (scp) and compare with the dump of the other firmware:"
say "  sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz"
