# BMC 硬件移植采集

脚本：`recipes-phosphor/utils/files/bmc-hw-dump.sh`。
镜像中安装为 `/usr/bin/bmc-hw-dump`。也可以单独复制脚本到厂商固件，使用 `sh` 执行。

```sh
bmc-hw-dump
# 厂商固件：
sh /tmp/bmc-hw-dump.sh
# 禁止直接 MMIO 和芯片 I2C 探测，使用操作系统提供的只读接口：
sh /tmp/bmc-hw-dump.sh -n -R
```

默认写入 `/tmp/bmc-hw-<hostname>-<time>-<pid>/`，并生成同名 `.tar.gz`。
`-o DIR` 修改输出目录，`-a` 在串口输出更多文本，`-s` 显式启用 I2C 地址扫描。
不需要重新构建固件即可单独运行更新后的脚本。

## 采集范围

| 接口 | 主要文件 |
|---|---|
| 完整设备树与二进制属性 | `device-tree.dtb`、可用时的 `device-tree-live.dtb`、`dt-hardware-cells.txt` |
| GPIO、复用、strap、驱动强度、时钟 | `gpio-*.txt`、`scu-regs.txt`、`clock-config.txt` |
| DDR 容量、ECC、VGA 保留、MR/时序、PHY ODT/RON、训练窗口/Vref | `memory-config.txt`、`memory-regs.txt` |
| I2C1–16、mux、温度、PSU、RTC、FRU | `i2c-devices.txt`、`bus-bindings.txt`、`chips.txt`、`eeprom-*.bin` |
| ADC 电压、PWM/TACH、CPU/DIMM 温度、开盖状态 | `hwmon-*.txt`、`iio-*.txt`、`block-regs.txt`、`board-config.txt` |
| eSPI、KCS、POST、VUART、UART/SOL/调试串口 | `espi-regs.txt`、`lpc-regs.txt`、`vuart-regs.txt`、`serial.txt` |
| PHY、RGMII 延时、NC-SI、MAC 来源、IP 和统计 | `network*.txt`、`net-layout.txt`、`mac-regs.txt`、`clock-config.txt` |
| BMC FMC、BIOS SPI1、预留 SPI2、MTD、JEDEC/SFDP | `flash-config.txt`、`mtd.txt`、`block-regs.txt` |
| VGA/KVM、USB UDC、gadget 绑定、HID 描述符、虚拟媒体/NBD | `console-vga.txt`、`usb-config.txt` |
| PECI、辅助设备、I3C、未绑定设备 | `bus-bindings.txt`、`dev-nodes.txt` |
| 电源/风扇/传感器配置、LED、watchdog、复位原因 | `board-config.txt`、`leds.txt`、`watchdog.txt`、`memory-config.txt` |

`port-guide-coverage.txt` 内嵌当前 `meta-ctopai/port_guide.xlsx` 的 159 个硬件配置与用途条目，
包含表格行号、SoC 资源/球位、器件/连接、地址/通道和采集文件索引。更新 guide 后需要同步脚本内的表格与 SHA256。
索引表示采集位置，不表示接口已经验证通过。新增移植参数的二进制属性统一看 `dt-hardware-cells.txt`。

## 边界

只读取已列出的配置寄存器，不发起 DDR 训练、PHY 页切换、Flash 切换、USB 重新枚举、驱动重新绑定。
不读取 KCS/SOL FIFO、USB endpoint/setup 数据、Flash 镜像或 watchdog 字符设备。
不强制访问被驱动占用的 I2C 芯片，不操作未知 CPLD、PROM 或 mux 寄存器。
日志最多取本次启动最近 3000 条；新增文本属性每项最多 64 KiB，板级配置文件每项最多 256 KiB。
缺少工具、权限或 sysfs/debugfs 属性时保留可用部分，工具清单与限制在 `hardware-limits.txt` 中。
不自动挂载 debugfs。缺少 `timeout` 的旧固件无法保证单条命令的等待上限。

DDR 芯片型号/速度等级、实际电压、晶振波形、电阻值、PCB 走线、未装器件等仍需要原理图和实测确认。
MMIO 数据是瞬时值，DDR MR 是控制器的编程值，不能当作 DRAM 芯片重新读回的值。

## 对比

在相同主机电源状态下分别采集厂商固件和新固件，将两个包复制到 PC：

```sh
sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz
```

默认对比增加了 DDR、时钟、MAC、USB、Flash 与总线绑定信息。实时统计和训练结果会变化，需结合原始包判断。
采集包含 MAC/IP、序列号与 U-Boot 环境，提供给第三方前检查这些内容。
