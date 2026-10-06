# CEB-GNRD 模拟器与主机侧控制面板

## 目的与集成位置

本目录扩展 QEMU AST2600 模型及主机侧行为，供真实 CEB-GNRD OpenBMC 镜像测试。
面板负责驱动硬件输入、注入故障并观察实际 BMC 输出。电源策略、UID LED、风扇策略、
KVM 服务和虚拟媒体挂载仍由 BMC 固件处理。

正式源码和补丁都在本目录；仓库根目录的 `.tutorial-build/qemu/kvm-usb` 是临时源码展开目录，
不参与构建，也不是运行依赖。QEMU 的 C 模型通过 `patches/0001..0025` 集成；
`recipes-devtools/qemu/qemu-system-native_%.bbappend` 引用同一组补丁。

## 构建与启动（Linux 构建机）

```sh
# 在 OpenBMC 构建环境中：构建固件和对应 native QEMU。
bitbake obmc-phosphor-image

# 启动镜像。
sh meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh
```

补丁目标为项目固定的 QEMU 11.0.2。启动脚本固定使用镜像 qemuboot.conf
中 `staging_bindir_native` 指向的 BitBake native QEMU；相对路径按配置文件所在目录解析。
配置或程序缺失会报错退出。
不会使用独立安装目录、PATH 中的 QEMU 或环境变量 `QEMU`。
完成 `bitbake obmc-phosphor-image` 后直接运行 `./run-qemu.sh` 即可。

旧的独立构建安装目录为 `~/qemu-ceb-gnrd/qemu`，源码和构建目录为
`~/qemu-ceb-gnrd/src`（构建输出在 `src/build`）。停止模拟器后可以删除这两个目录。
请保留 `~/qemu-ceb-gnrd` 本身，其余文件包括 FRU、日志和面板上传图片仍供模拟器使用。

FRU EEPROM 使用四个 256 字节地址块（0x50～0x53），每块使用单字节偏移。
`fru0.bin`～`fru3.bin` 文件各保留 512 字节长度以满足块设备对齐，实际 EEPROM
仅使用前 256 字节。已有文件会保留，BMC reboot 不应使写入内容回退。
此配置需要 QEMU 补丁 0025；更新后须重新构建镜像及 native QEMU。

`ipmitool fru gen` 默认 Chassis PN 为 `93-XXXXX-XX`、Board PN 为 `91-59380-A0`、
Product PN 为 `81-59380-A0`；名称为 CEB-GNR-D、制造商 CTOPAI，序列号默认为
UTC 日期加 0001。交互生成时可以修改各字段。
FruDevice 写入后会读回物理 EEPROM 并比对；成功日志 `FRU EEPROM write verified`
包含设备路径、偏移及长度。读回不一致会记录 `write/readback mismatch` 并返回失败。
更新后重新写入 FRU，再比较写入后及 BMC reboot 后的 `ipmitool fru print 0`。
`build-qemu.sh` 保留为独立构建工具，不用于本启动脚本。

只有旧补丁的 QEMU 会提示缺少 0018，不能用于新增 eSPI/USB/CHASI# 检查。

| 环境变量 | 默认值 / 用途 |
|---|---|
| DEPLOY | ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd |
| STATE | ~/qemu-ceb-gnrd；QMP、FRU 文件、运行日志及面板上传的 VGA 图片 |
| BIOS_FLASH | ~/qemu-bios.bin，64 MiB BIOS 模拟 Flash |
| PANEL_PORT | 8800，硬件模拟控制台 HTTP 端口 |
| NO_PANEL=1 | 隐藏面板，仍运行主机 COM1、USB、VGA 辅助线程 |
| NETWORK_CAPTURE=1 | 抓取管理网卡 Ethernet 包到 STATE/management.pcap，贯穿 BMC reboot |
| PECI_CPU=gnrd / spr | 默认 GNR-D 温度模型；spr 保留上一代 SPR 模型用于比较 |

仅保留 Web 面板，运行脚本后访问 http://127.0.0.1:8800，无需设置 PANEL_WEB。
面板使用 Python 标准库，不需要 Tk 或 Pillow。左侧为操作分页，右侧固定显示
硬件连接和事件日志。拖动中间分隔线可调整左右比例，浏览器会记住比例；
双击分隔线恢复默认比例，也可聚焦分隔线后用左右方向键调整。
信号图中的 Fault 故障灯读取 GPIOI5 / offset 69 / BMC_SYS_ALERT_LED：
高电平点亮（红色），低电平熄灭；显示当前亮／灭状态，并记录电平变化。

事件日志默认过滤 BMC_HBLED_N 心跳记录，勾选“显示 HB 日志”可查看；
该开关仅过滤面板显示和复制内容，不影响 GPIO 采样、心跳图示及原始日志。

## BMC Web 和模拟面板的访问

| 服务 | QEMU 所在机器上的地址 | 说明 |
|---|---|---|
| BMC Web / Redfish | https://127.0.0.1:8443 | 转发至 BMC eth0 192.168.185.200:443 |
| BMC SSH | 127.0.0.1:2222 | 转发至 BMC 22 |
| IPMI LAN | UDP 127.0.0.1:2623 | 转发至 BMC 623 |
| CEB-GNRD 硬件模拟控制台 | http://127.0.0.1:8800 | Python 主机模拟器，非 BMC Web |

转发只绑定回环地址。从其他电脑访问，可建立 SSH 隧道：

```sh
ssh -N -L 8443:127.0.0.1:8443 -L 8800:127.0.0.1:8800 test@构建机地址
```

然后在本机浏览器访问 https://127.0.0.1:8443 和 http://127.0.0.1:8800。
初始 BMC HTTPS 证书可能需要浏览器确认。若 BMC 已保存其他 eth0 IP，
启动脚本的固定转发目标不会自动跟随更改。

### Web 无法访问时

先保存故障现场，使用本目录只读脚本：

```sh
# QEMU 所在 Linux 机器
sh meta-ctopai/meta-ceb-gnrd/tools/qemu/diagnose-web.sh host > /tmp/web-host.txt

# 将 diagnose-web.sh 复制到 BMC 后，在 BMC 串口中执行
sh /tmp/diagnose-web.sh bmc > /tmp/web-bmc.txt
```

| 现象 | 下一步 |
|---|---|
| 构建机 8443 无监听 | 查 QEMU 是否运行、启动参数、qemu.log 中端口冲突 |
| TCP 可连接但 TLS 超时 | 不能证明到达 BMC；查 BMC 本机 curl、eth0 IP 和链路 |
| BMC 本机 HTTPS 有 HTTP 响应，转发不通 | 查固定转发 IP、MAC/网卡配置、网络过滤 |
| BMC 本机 HTTPS 也不通 | 查 bmcweb service/socket、journal、资源耗尽和崩溃 |
| Redfish 正常但网页打不开 | 查网页根路径、静态资源、浏览器 Console/Network、证书 |

无需登录的探针得到 HTTP 200 或 401，只能证明该 HTTP 路径有响应，
不能证明登录、传感器或所有 Redfish 功能均正常。
bmcweb.socket 可以由 systemd 持有 443；只看 bmcweb 进程不足以判断可访问性。
不要在采集日志前先重启。只读脚本不收集密码，不修改服务或网络。
`ceb-gnrd-check` 默认只读；仍应先用上面的故障现场采集脚本保存时间线，
再运行完整检查。完整检查会访问 IPMI、D-Bus、Redfish，可能需要几分钟。

### 固件接口检查

在 BMC 串口运行（参数 `0` 是当前模拟器，`1` 是实机）：

```sh
ceb-gnrd-check 0
# 登录密码不是默认值时：
BMC_PASSWORD='你的密码' ceb-gnrd-check 0
```

结果分为 `PASS`、`FAIL`、`SKIP`、`INFO`，失败时退出码为 1。
`SKIP` 表示需要额外操作，不能当成接口通过。检查不再沿用“QEMU 没有
风扇、PECI、RTC、FRU”的旧假设；按已安装的板级配置检查各路 ADC、温度、
风扇和已绑定的 PSU，主机关机时跳过仅在开机时有效的读数。

默认保留风扇参数、LED 状态、FRU、日志和主机/BMC 电源状态。
只有显式设置 `CEB_CHECK_CLEAR_LOGS=1` 才执行事件日志 ClearLog（会删除日志）。
旧的 `CEB_CHECK_KILL` 和风扇写入演练已取消。

报告为 `/tmp/ceb-gnrd-check/report.txt`，诊断包为
`/tmp/ceb-gnrd-check.tar.gz`。单个子命令默认 15 秒，传感器列表最多 40 秒；
单份命令输出最多 256 KiB，报告约 2 MiB，诊断目录约 4 MiB，加上压缩包
临时占用 `/tmp`，不会把检查报告写到 SPI Flash。密码不写入命令行/报告。
重复运行覆盖上一份报告；并发运行由 `/run/ceb-gnrd-check.lock` 阻止。

从 Linux 构建机取回报告：

```sh
scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz .
```

接口完整验证需要配合面板/浏览器操作：

| 场景 | 操作与判定 |
|---|---|
| 虚拟媒体 | 在 BMC Web 挂载镜像并保持会话；再运行检查，验证 NBD 容量、客户端和 UDC 绑定；面板读取容量/首扇区，再弹出确认 gadget 清理 |
| KVM/HID | Web KVM 输入键盘/鼠标，面板确认收到报告；切换内置 VGA 图，在 Web KVM 确认画面改变 |
| SOL/eSPI | Web SOL 与面板 SOL 双向发送文本；不能只凭 tty/服务存在判定通信通过 |
| 传感器/风扇 | 面板改变温度/电压/PSU 状态，观察 IPMI/Redfish/Web 新读数；改变风扇控制后观察 PWM/TACH，最后恢复原参数 |
| GPIO/机箱 | 面板按 UID/电源/复位按钮，开合机箱，核对灯、主机状态和事件；检查脚本不自动按按钮 |
| RTL8211/NC-SI | 面板注入链路断开/速度变化、NC-SI 通道切换，核对 carrier 和日志；注入故障时链路检查失败是预期结果 |
| Power Restore | 三种策略分别在停止/启动 QEMU 的 AC 恢复中验证；软件/watchdog reset 保留原主机状态。脚本收集 power-on/warm 原因和策略日志，不自动复位 |
| FRU/POST/容量 | 控制写 FRU 后分别重启 BMC/QEMU核对持久化；连续三轮 BIOS 启动后仅保留最新两轮 POST；检查剩余空间和日志预算 |

这些检查仍需要在新固件中实际运行；接口元数据正常不等于所有数据路径已验证。

针对“BMC reboot 后需要先 ping 网关，8443 才能恢复”的现象，可用
`NETWORK_CAPTURE=1 sh meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh` 启动。
依次记录首次访问、BMC reboot、8443 失败、BMC ping 网关和 8443 恢复。
management.pcap 可比较发送给 BMC 的目标 MAC 与重启前后地址，以及 ARP/TCP 顺序。
抓包仅用于诊断，不自动发送 ping、不修改 BMC 网络配置，也未宣称修复故障。

### 固定 U-Boot 默认 MAC

板级 `recipes-bsp/u-boot/files/ceb-gnrd-env.h` 已加入本地管理地址：

| 环境变量 | 默认值 | 设备树别名 / 接口 |
|---|---|---|
| ethaddr | 02:26:00:00:00:01 | ethernet0 → mac1，物理 MAC2 / RGMII，Linux eth0 |
| eth1addr | 02:26:00:00:00:02 | ethernet1 → mac2，物理 MAC3 / NC-SI，Linux eth1 |

用户已观察到 eth0 在 BMC reboot 后改变地址，且只需 ping 网关即可恢复 Web；
Linux 日志显示地址从网卡寄存器读取，`fw_printenv` 显示两项变量未配置。
这与 QEMU 网络后端保留旧 IP→MAC 映射、出站 ARP 更新映射后恢复一致。
固定地址针对该变化来源；未修改 bmcweb，也未添加自动 ping。

重新构建 U-Boot/固件后，默认值只在使用默认环境时生效。
已有有效 Flash 环境不会自动合并新默认值；常规 BMC 更新还会保留 U-Boot。

### BMC Web 固件更新的分区选择

在 Firmware 页面选择 BMC 的 `.static.mtd.tar` 分区更新包后，会显示：

| 分区 | 默认选择 | 说明 |
| --- | --- | --- |
| kernel / rofs | 是 | 必须一起更新，避免内核与根文件系统版本不匹配 |
| rwfs | 是 | 更新可写文件系统，仅恢复现有 whitelist 中指定的设置；取消选择则保留整个 rwfs |
| u-boot | 否 | 勾选时必须确认：写入失败或断电可能无法启动，也无法通过网络恢复 |
| u-boot-env | 否 | 勾选时必须确认：清除保存的 MAC 地址及其他启动参数，恢复固件默认值 |

environment 不从更新包取旧数据，而是将 128 KiB 分区写为擦除状态。
保存的 MAC 地址被清除后可能出现地址冲突或网络不可达，需要重新配置。
更换文件、取消选择后再次勾选，均需要重新确认。取消确认不会选中分区。
BIOS 更新沿用自己的分区选择，不受 BMC 选项影响。

选择以 `bmc-partitions.txt` 随本次上传包传递，固件激活时再次校验，并仅暂存选中的分区。
未携带选择的传统更新默认保留 U-Boot/environment。
整片 `.static.mtd.all.tar` / `image-bmc` 更新被拒绝，防止绕过选择覆盖其他分区。
暂存失败会将激活标为失败，清除待刷写数据，不触发成功后的自动重启；
实际刷写失败会停止后续分区写入。更新过程仍需持续供电。

如果当前固件尚无此页面，先按默认方式更新到包含本功能的固件，
再通过新页面上传分区包并确认 U-Boot 更新。Power Restore 的复位原因逻辑
需要新版 U-Boot；只更新 kernel/rofs 不会升级旧 U-Boot。
本功能尚未进行 Linux 构建和模拟器/实板刷写验证。
在当前模拟 BMC 中可直接补齐缺失变量，无需重刷整个 Flash：

```sh
# 仅用于当前已确认两项变量均未配置的模拟实例。
fw_setenv ethaddr 02:26:00:00:00:01
fw_setenv eth1addr 02:26:00:00:00:02
fw_printenv ethaddr eth1addr
reboot
```

重启后先记录 `ip link show eth0`、`ip link show eth1`，不要先 ping，
从 QEMU 所在机器访问 8443；再次 reboot 后确认地址保持不变和 Web 可直接访问。
NC-SI 端口在 U-Boot 中保持禁用，eth1 的 Linux 地址传递也需运行核对。
这些默认值用于单实例开发；真实板卡应写入每板唯一生产 MAC，
并发模拟实例也应使用不同地址。不要清空整个环境来迁移 MAC。

## 模拟接口与范围

| 接口 | 模型 / 行为 |
|---|---|
| 电源、复位、PWRGD、BIOS_BOOT_OK | bmc-host-sim 原有 GPIO 电源时序，POST、BIOS 卡死、强制断电 |
| 前面板电源 / UID 按钮 | 按下及释放输入；LED 是否点亮由实际 BMC 按钮与 LED 服务决定 |
| eSPI Peripheral | SW_READY、RESET#、错误 IRQ；主机 legacy I/O 路由到 KCS3、80h 和 COM1 |
| eSPI Virtual Wire | 就绪、BMC BOOT_STATUS/BOOT_DONE、原始 SYSEVT 位；不含完整 VW 包交换 |
| POST 80h | 通道未就绪时不能写入；原生主机 POST 等待通道及 BMC boot wires；历史最新在前 |
| COM1 / SOL | 双端 UART FIFO：主机 I/O 经 eSPI 到真实 ttyVUART0；新模型不走直连串口 socket |
| KCS3 | 主机 ca2/ca3 状态机，BMC 实际 KCS 驱动和 IPMI 服务生成回复 |
| CHASI# | 开盖输入及 sticky latch；合盖不直接清除，由 BMC 服务重新布防 |
| PWM / TACH | 六路风扇转速跟随 PWM，也可注入停转、固定转速；GPIOI6 由真实 owner 服务控制 |
| ADC | 面板统一输入电源轨 V；按 Entity Manager ScaleFactor 自动计算引脚电压 |
| PECI | CPU 0x30 的温度和模拟包配置寄存器，随主机电源在线 / 离线 |
| 温度 I2C | Linux i2c-6，0x48..0x4b，tmp105/LM75 兼容 |
| PSU | Linux i2c-7，0x58/0x59 在位、0x5a 默认空槽，负载、温度、AC loss、插拔 |
| RTC | Linux i2c-9，0x6f，NCT3018Y/NCT3015Y 类模型 |
| FRU / PCIe EEPROM | Linux i2c-10 的四个 FRU 块，及 i2c-0..5 的槽位 EEPROM |
| VGA / KVM | 800×600 JPEG 输入、信号切换，BMC 真正 video capture/ikvm 链路 |
| USB vHub | 控制传输、HID interrupt IN、bulk IN/OUT 和 IN descriptor DMA；真实 BMC gadget |
| 虚拟媒体 | 主机 USB 枚举、SCSI INQUIRY / READ CAPACITY / READ(10) 首扇区；不写媒体 |
| BIOS SPI | 64 MiB 模拟 Flash；支持原有 BMC BIOS 更新链路 |
| 网络 | 保留现有 QEMU user network / NC-SI 行为；按要求未新增 RTL8211FS / E810 专用模型 |

### ADC：填写测量到的电源轨电压

例如 P12V_SYS 输入 12.1（V），面板执行
`pad_mV = round(12.1 * 1000 / ScaleFactor)`。
分压通道显示 ÷N，直接输入通道显示直连。表中同时显示引脚电压。
超过 2.5 V 参考范围仍会饱和，不把错误的电气配置隐藏成正常读数。
D3V0_BAT0 当前 ScaleFactor=1，3 V 输入会饱和；实板是否有分压须核对原理图/装配。
该传感器保留电压读数，不配置任何阈值，不产生电压越限告警。

### KVM、键盘与虚拟媒体的操作顺序

1. 开启模拟主机，让 BMC 进入正常运行状态。
2. 面板 VGA 页选择 800×600、baseline、三分量 JPEG（最大 192 KiB），或使用内置 POST/OS 图。
   面板预览的是主机输入；在 **BMC Web KVM** 中查看实际捕获输出。
3. 在 **BMC Web KVM** 输入键盘/鼠标；面板显示 gadget 发出的真实 HID 报告。
   文本解码只覆盖基本 boot keyboard 键，其余格式保留十六进制报告。
4. 在 **BMC Web 虚拟媒体页** 挂载 ISO/IMG，保持浏览器会话在线；
   面板虚拟媒体页选择实际枚举的存储端口，读取容量和 LBA0 SHA-256。
5. 弹出操作仍在 BMC Web 完成；面板只显示主机 USB 侧检查。
   读取结果是最近一次手动检查，换镜像或弹出后需要重新检查。
   若 BOT 失败/STALL 后无法重试，使用“重新枚举”重置 USB 连接再检查。

这里不执行 x86 BIOS/OS，也不把键盘报告写入假 BIOS 或用面板直接挂载镜像绕过 BMC。
实机连续 VGA 图像、精确 USB 时序、启动可用性仍须板卡验证。

HID 在主机关机、BMC 重启或 USB 重新枚举时会取消未完成的端点请求。
`-108`（`ESHUTDOWN`）表示端点关闭，本身不代表键盘传输故障；内核补丁
0005 将这些预期取消改为调试日志，其他传输错误仍保留错误提示。
若主机稳定运行时反复断开，请同时收集面板 USB 连接日志和 BMC 内核日志。

## CLI 与 QMP

`host-sim.py` 默认从 stdin 接收命令，`--web` 打开浏览器面板，
`--headless` 保持主机辅助线程。QMP socket 是 STATE/qmp.sock。

| 命令 | 用途 |
|---|---|
| power / power-hold / uid / powerfail | 主机输入及故障 |
| hang on\|off / post 秒 / shutdown 秒 | BIOS 卡死和时序 |
| temp inlet\|outlet\|pcie\|m2\|all 摄氏度 | I2C 温度 |
| cpu 摄氏度 / dimm 摄氏度 | PECI 温度 |
| adc 通道 电压V | 电源轨电压，自动分压 |
| fan 0..5\|all rpm\|auto / fan max rpm | 风扇故障和模拟上限 |
| psu 槽位 in\|out / psu 槽位 ac on\|off / load W / temp C | PSU 故障 |
| rtc battery ok\|low | RTC 电池 |
| postcode 十六进制 | 经 Peripheral 写 80h |
| chassis open\|closed | 开盖、合盖 |
| espi reset assert\|release | eSPI 链路复位 |
| espi vw MASK VALUE / espi error MASK | 十六进制 VW 位及 Peripheral 错误 |
| ipmi 18 01 | 经 KCS 的 Get Device ID 示例 |
| usb reconnect / usb media 端口 | USB 重枚举 / 只读媒体检查 |
| vga PATH / vga auto\|on\|off | VGA 图片和信号 |
| status / quit | 状态 / 退出 CLI |

QMP 对象包括 /machine/soc/espi、/machine/soc/usb-vhub、
/machine/soc/chassis、/machine/soc/video-engine、/machine/peripheral/host、
/machine/soc/adc、/machine/soc/pwm、/machine/soc/peci 和 psu0..2。
新模型不支持迁移/保存恢复控制器状态；请完整重启模拟器。

## 日志与核对状态

### 虚拟媒体检查与已修正问题

浏览器 NBD 会话经 bmcweb 管道连接 nbd-proxy / nbd-client，内核建立
`/dev/nbd0` 后由 state hook 绑定只读 USB mass-storage gadget。
模拟器只模拟主机 USB 一侧：主机开机后枚举 gadget，读取 INQUIRY、
READ CAPACITY(10) 和 READ(10) LBA0；不绕过 BMC，也不模拟 x86 从镜像启动。

2026-10-06 源码检查修正：

- jsnbd 回收子进程时遇到 ECHILD 会停止，避免无子进程后的死循环。
- 管道关闭产生 EPIPE 时正常退出并清理，不再被 SIGPIPE 直接终止。
- 停止时先等待尚未完成的 gadget 启动脚本，避免 ConfigFS 启停并发。
- gadget 创建失败会回滚，UDC 按完整名称检查占用，无可用 UDC 则明确报错。
- 通过代理 PID 和配置编号标记 gadget 所有者，失败的另一个会话不能删除它。
- 浏览器建立连接期间也能停止；停止/断开时取消 FileReader，避免迟到的读取
  回调向已关闭的 WebSocket 发送数据；实际打开连接后才显示服务启动。

- NBD 客户端显式选择空导出名（`-N ""`）和 EXPORT_NAME 协商（`-g`），
  避免当前 nbd-client 在 `-L` 模式下拒绝启动。
- 挂载后内核的较大读请求会产生超过 bmcweb 131088 字节接收限制的响应。
  浏览器将完整 NBD 响应按顺序拆为 64 KiB WebSocket 消息；bmcweb 写完
  当前消息到代理管道后才读取下一条，避免接收缓冲区溢出和管道积压。
  Firefox Console 首次拆分时记录请求 offset、length 和 websocketChunk。

用户日志已确认 NBD 协商与 gadget 绑定成功，但随后出现
`The WebSocket operation caused a dynamic buffer overflow`，引发 NBD socket
关闭和 sector 128 I/O error。该错误属于浏览器/bmcweb 传输层；关闭后的
NBD size=0、gadget 消失是正常清理结果，不能据此判定 USB 模型枚举失败。

这些是源码修复，不代表虚拟媒体已通过端到端验证。当前检查未发现确定的
模拟器 Bulk/SCSI 根因；READ CAPACITY(16) 和镜像启动仍不在探测功能范围内。

更新固件后先开启模拟主机，在 BMC Web 挂载 ISO/IMG，再在模拟器的
虚拟媒体页选择枚举出的存储端口，执行“读取容量和首扇区”。应返回
`read_ok=true`、正确容量和 `lba0_sha256`。停止后 gadget 应移除，下一次挂载
应能重新枚举；同时 BMC Web 应持续可访问。

失败后将 `diagnose-virtual-media.sh` 复制到 BMC，使用 `sh` 执行并回传输出，
再回传构建机当前的 `tail -n 100 ~/qemu-ceb-gnrd/panel.log`。
NBD size=0 且无 pid 表示后端尚未建立，不能归因于主机 USB 读盘；
size 正常但未绑定 UDC 时检查 hook；已绑定而未枚举时检查 USB 模型/主机状态；
已枚举但 read_ok=false 时检查日志中的 SCSI sense、CSW 和超时。

### AC 恢复与 BMC 重启

0024 补丁为 AST2600 提供 SCU064/06C 复位事件日志：新建 QEMU 进程表示
AC 上电，产生 POR；同一进程内的 BMC 软件重启、watchdog 和 QMP reset
均为 warm reset。watchdog 记录对应编号和模式；事件日志支持 W1C 清除，
未清除的标志在 warm reset 后保留。

板级 U-Boot 在清除日志前保存原值，通过内核设备树 `/chosen` 传递
`aspeed,reset-log`、`aspeed,reset-log3` 和 `aspeed,boot-reason`。
只有确认 POR 且没有其他复位来源才使用 `power-on`；其他来源为 `warm`，
没有有效原因则为 `unknown`。不会用持久化环境变量或清洁关机标记推断 AC。

Always Off、Restore、Always On 都只在 `power-on` 时应用。BMC warm reset
不重新执行策略，主机已有状态保持；同一内核启动中每个主机只消费一次 AC
事件，电源服务重启也不能重复执行。原因缺失或无法创建消费标记时跳过策略。
因此必须同时更新 U-Boot、BMC 固件和 QEMU；仅升级 rootfs 或继续使用旧
U-Boot 会显示 unknown，AC 恢复策略也会跳过。源码修改尚待 Linux 构建与运行验证。

串口查看原因与策略日志：

```sh
tr -d '\000' </sys/firmware/devicetree/base/chosen/aspeed,boot-reason
echo
journalctl -b --no-pager | grep -E 'AC boot|Skipping power restore|Invoking Power Restore'
```

- panel.log：主机辅助线程及操作日志。
- host.log：QEMU 原生主机电源/POST 状态 trace。
- qemu.log：QEMU 组件 stderr；BMC UART 留在启动终端。
- 内核普通 warning/info 在 dmesg/journal 保留；板级 console 策略仅打印 error 及以上。
  BMC 中 `dmesg -n 8` 可临时恢复详细串口打印。

本轮只进行了源码静态检查、Python/JS/shell 语法检查及补丁检查，
未编译新增 QEMU 模型，未验证 KVM、USB、eSPI 的运行结果。
固件风险及确认的修复见 [FIRMWARE-REVIEW.md](FIRMWARE-REVIEW.md)。
UID/GPIOI6 原因仍需要实际运行输出；可复制 diagnose-bmc.sh 到 BMC 后执行采集。

PECI 默认模拟 GNR-D：CPUID 示例 0x000a06e0，Family 6 / Model 0xAE、PECI 4.2。
需要构建新增的 0019 补丁；`PECI_CPU=spr sh tools/qemu/run-qemu.sh`（从板级目录）
可切回 SPR 作比较。CPUID 的 stepping 只是模拟示例，不是读取到的真实板卡签名。
GUI 的 CPU / DIMM 温度控件仍通过现有 QMP 属性驱动，BMC 从真实 PECI 驱动读取。

内核 0003 已替换原来复制 EMR 表的做法：CPU 读取封装温度、跳过核心掩码，
GNR-D 的 PCS 14 暴露八个通道最高温度，由温度服务计算 DIMM_MAX_TEMP。
不再使用 SPR/EMR 的 DIMM 阈值寄存器，BMC 汇总传感器的报警阈值仍由板级服务设置。
若 BIOS 使用 CLTT with PECI wire / PECI_UPDATE，PCS 14 返回零，
其 DIMMTEMPSTAT MMIO 路径尚缺寄存器规范；不能声称已覆盖该模式。
全零或读取错误会保持内核温度不可用，现有服务在主机开机时使用 FAILSAFE_TEMP=90°C
驱动保护策略；这一替代值不是实测温度。模块版本、AMI BIOS 实际模式和真实读数需验证。
模拟温度正常不能作为该硬件兼容性已验证的证据。

未实现：eSPI OOB/Flash/full VW 包协议、电气/复位精确时序、CPU I3C3、
CPU SMBus 固件通信协议、专用 PHY/E810、完整 USB 主机控制器和运行中的 x86 主机。

## 2026-10-05 后续修复状态

当前补丁共 22 份（编号到 0021，两份不同用途的 0020）。新增 0020 修正已关机时的强制关机脉冲释放误开机；新增 0021 修正 VGA 无信号检测和 USB EP0/reset 握手，并提供诊断。必须重建 QEMU 才会生效。

GUI 采用左侧功能 Tab、右上固定硬件连接、右下固定事件日志；日志支持复制和清除、保留 2000 条。GPIO 边沿为 50ms 最佳努力采样，不能保证捕获每个短脉冲。上传图片预览不等同于 BMC Web KVM 捕获成功。

USB 支持检查 boot 键盘及 OpenBMC 六字节绝对鼠标报告；媒体由 BMC Web 挂载，GUI 只读检查 INQUIRY、容量和 LBA0，记录握手/SCSI 错误。没有客户端连接时 HID 节点缺失不能单独判定固件错误。

风扇 owner、PSU 生命周期和 Web 电源刷新另有固件修复，需要构建固件。详细根因、文件及待验证项见 `CHANGE-REPORT-2026-10-05.md` 第 11 节。所有新增端到端功能仍待用户运行验证。

#### 虚拟媒体诊断日志

BMC 的 `journalctl -b -u bmcweb.service --no-pager` 中，`virtual-media[配置号,pid=...]`
记录代理会话、nbd-client 启动及超时配置、NBD 设备就绪、双向首次传输、断开原因和累计字节。
`virtual-media[配置号,proxy=...,hook=...]` 记录 gadget 操作阶段、NBD 扇区数、UDC 选择、LUN 绑定、解绑及回滚。
不同会话用代理 PID 对照；不会记录镜像内容或每个传输包。

模拟器 `~/qemu-ceb-gnrd/panel.log` 记录 USB 枚举、SCSI CDB/CSW、sense 错误、NAK 超时，
以及媒体检查的 INQUIRY、容量、LBA0 SHA256、失败阶段和耗时。这些读盘日志在点击“读取容量和首扇区”时产生。
故障后在 BMC 执行 `sh diagnose-virtual-media.sh` 收集状态，并保留相同时段的 panel.log。

#### NBD 3.27 启动参数兼容性

如果日志出现 `not enough information specified, and argument didn't look like an nbd device`，
且 NBD size=0、pid 不存在，说明 nbd-client 在参数检查时退出，尚未建立后端或绑定 USB gadget。
代理必须显式指定默认导出名（`-N ""`）。本平台同时指定 `-g`，直接使用浏览器实现支持的
EXPORT_NAME 协商，并以 `-R` 保持只读。启动日志包含完整参数（空导出名显示为 `<empty>`）。
修复需重建并运行新 BMC 固件，QEMU 模型无需因此重新编译。

复位事件寄存器地址与固定 U-Boot 的 `platform.h` 一致：SCU064（0x1e6e2064）及
SCU06C（0x1e6e206c）。旧版 0024 模型误写 SCU074/078，导致传给 Linux 的快照为零、
boot-reason=unknown，AC 策略被跳过。修正后每次 SoC reset 在 qemu.log 输出两项标志，
可与 U-Boot 串口的 `BMC boot reason` 及 Linux chosen 属性对照。

### 内置 VGA 图片与 USB 状态

VGA / USB 页提供“内置图片 1 · BIOS POST”和“内置图片 2 · OS 控制台”按钮，
直接使用仓库中的 800×600 baseline JPEG，无需上传。选择图片不强制主机开机或开启 VGA 信号；
关机时显示参考预览，实际视频采集应在主机开机后的 BMC Web KVM 中核对。
“自动 POST / OS”恢复按主机状态自动选择。

USB 页的“无端口错误”对应空的错误集合，不代表已经收到键盘报告。
主机关机时模拟 USB 主机不枚举，提示等待上电；键盘输入须在 BMC Web KVM 中发送。
原始 USB / VGA 寄存器计数放在折叠的诊断详情中，真正的枚举/传输错误仍直接显示并写入 panel.log。

### 日志保留与容量预算

| 内容 | 保留限制 |
| --- | --- |
| POST 历史 | 最近 2 轮 BIOS POST，每轮最多 512 条；升级时迁移最新两轮并删除旧档 |
| Web POST 表格 | Created 默认倒序，同一秒内按 POST 接收顺序倒序 |
| IPMI SEL 文件 | 15 KiB 轮转，保留当前文件和 1 份历史 |
| Redfish 事件文件 | 64 KiB 轮转，保留当前文件和 1 份历史 |
| systemd journal | 持久日志预算 1 MiB，最多 8 个文件；运行时日志预算 8 MiB；最多 2 天 |
| systemd core dump | 不保存 core 二进制；journal 保留最新崩溃摘要，启动时清理旧 core 文件 |
| BMC 诊断转储 | 总预算 512 KiB，单份预算 200 KiB |
| D-Bus 事件条目 | 错误最多 64 条，信息最多 64 条 |
| 模拟器 panel.log / qemu.log / host.log | 每类当前文件和 .1 各最多 8 MiB（合计最多 48 MiB） |
| 可选 management.pcap | 默认关闭；达到 64 MiB 后停止抓包，仿真器继续运行 |

SEL/Redfish 每分钟检查一次，突发写入可在检查前超过轮转阈值；
journal 的预算是清理目标，活动文件可能短暂超出。
抓包每秒检查，达到阈值时保留文件，大小可多出该检查间隔内的流量。
这些限制不会影响固件镜像、BIOS Flash 或 FRU EEPROM 文件。

POST 管理器保留所有实际接收的码值，包括 `0x00`、重复的 `0x01` 及多字节码；
同一微秒内收到的多条记录也按接收顺序保留，不通过码值推断新一轮启动。
收到主机 `CurrentHostState=Off` 时，先保存当前轮并取消待写入的定时器，再结束该轮；
下一条 POST 记录开始新一轮。连续 Off 事件但没有新数据时，不增加空轮。
本平台 x86-power-control 在 `BMC_BIOS_BOOT_OK` 撤销后进入热复位检查，
同样发出 HostState Off，因此可识别主机电源保持开启的正常 BIOS 热重启。
若实机在 POST 期间复位且没有主机状态/完成信号变化，继续记录在当前轮，
不能仅凭重复起始码准确判断复位；需接入该硬件可观测的复位事件后再分轮。
保持最近两轮、每轮最多 512 条及 Web 最新在前的限制。

板级 SPI Flash 为 64 MiB，其中 rofs 为 44 MiB、rwfs 仅 10 MiB。
日志与配置共同使用 rwfs；镜像剩余空间不能代替 rwfs 剩余空间。
持久 journal 1 MiB、诊断转储 512 KiB、SEL/Redfish 约 158 KiB，
合计约 1.66 MiB，另外还需计算按条数限制的 D-Bus 事件、两轮 POST、配置及文件系统开销。
journal 设置至少保留 4 MiB 空闲作为清理目标；这不是其他程序写入的全局磁盘配额。
core 二进制不再写入 Flash，也不再生成堆栈分析；崩溃信号、进程和服务重启原因仍记录在 journal。
升级后启动清理旧 core 载荷并压缩 journal 保留范围，不删除业务配置。
实际容量需在 BMC 检查 `df -k /var/lib /var/log` 和 `du -k -d 2 /var/lib /var/log`，
应保留至少 4 MiB 空闲；若不足，需要定位实际占用，不能只依靠配置预算保证。

### RTL8211FS 与 Intel NC-SI 网络测试

0026 补丁随 BitBake 的 qemu-system-native 构建；更新后重新构建镜像并运行
`./run-qemu.sh`。启动脚本检查模型属性，拒绝使用缺少补丁的旧 QEMU。
在模拟器 Web 面板的“网络”页切换网线、速率、NC-SI 通道、命令超时和 NIC 复位。

| 接口 | 模拟内容 |
| --- | --- |
| MAC2 / eth0 / RTL8211FS-CG | MDIO 地址 2、PHY ID 001cc916、Clause 22、分页寄存器、RGMII 延迟配置读写、复位、自动协商状态、掉线/恢复、10/100/1000 Mbps 全双工 |
| MAC3 / eth1 / Intel E810 NC-SI 配置 | package 0 两通道；发现、选择、启停、TX 通道选择、链路查询、链路/配置 AEN、MAC/VLAN/IPv4 广播/IPv6 多播过滤、能力/版本/统计、UUID、Intel OEM MAC 地址与 Keep PHY 命令 |
| NIC 供电 | 跟随模拟主机供电；主机关机时不应答、不收发数据。BMC 软件重启不切断主机或 NIC 供电；无需浏览器面板参与 |
| 故障注入 | 各通道掉线/恢复、两通道均无链路、停止命令应答、NIC 复位后重建配置；未知命令返回不支持，校验错误计数并丢弃 |

原来的管理访问地址和端口保持不变：BMC Web `https://127.0.0.1:8443`、
SSH 2222、IPMI UDP 2623。管理网线断开后这些转发不可用，可在模拟器面板恢复。
eth1 使用独立 user 网络并通过 DHCP 获取地址，默认没有入站端口转发。
两个 NC-SI 通道共享同一个网络后端，适合测试通道选择和切换，不能代表两条独立物理网络。

NC-SI 的外网速率可切换为 1/10/25/100 Gbps（默认 25 Gbps）；BMC 与 NIC 之间
的 RMII 仍为 100 Mbps。速率模拟只改变软件可见状态，不限制吞吐量。
Linux 默认用 DGMF 禁用多播过滤，此时全部多播通过；启用单项过滤时只解析基础头的
ND、路由、DHCPv6 和 MLD，扩展头多播需禁用全局过滤。
统计中没有模拟的硬件错误/字节计数返回零，不应拿它们评估吞吐量。
该模型用于 BMC 协议和驱动测试，不包含 E810 PCIe 主机驱动、SFP、电气时序、
实际自动协商延时、半双工冲突、NIC 固件升级或完整厂商 OEM/PLDM 功能。
QEMU 快照格式随新 MAC 状态升级；旧版保存的内存快照不兼容，Flash/FRU 文件继续使用。

源码中核对了 Linux 的 Realtek 驱动和 NC-SI 命令/响应布局；尚未在 Linux 上编译、
启动固件或确认通道切换结果。固件运行时可检查：

```sh
ip -br link
ip -br addr
cat /sys/class/net/eth0/phydev/phy_id
cat /sys/class/net/eth0/carrier
cat /sys/class/net/eth1/carrier
journalctl -b -u ceb-gnrd-ncsi.service --no-pager -n 80
dmesg | grep -Ei 'realtek|rtl8211|ftgmac|ncsi'
```

`~/qemu-ceb-gnrd/host.log` 记录模型识别、NC-SI 命令/响应结果、供电与配置重建；
常规链路查询不逐次刷日志。`panel.log` 记录人工操作及链路、速率和供电变化。
面板诊断详情包含 MDIO 访问、命令、响应、AEN、校验错误、丢包和通道状态计数。
BMC 的 `ceb-gnrd-ncsi.service` 日志记录接口启停、carrier 变化与重试。
这些新增日志继续使用现有轮转和容量限制。
