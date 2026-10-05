# CEB-GNRD 模拟器与主机侧控制面板

## 目的与集成位置

本目录扩展 QEMU AST2600 模型及主机侧行为，供真实 CEB-GNRD OpenBMC 镜像测试。
面板负责驱动硬件输入、注入故障并观察实际 BMC 输出。电源策略、UID LED、风扇策略、
KVM 服务和虚拟媒体挂载仍由 BMC 固件处理。

正式源码和补丁都在本目录；仓库根目录的 `.tutorial-build/qemu/kvm-usb` 是临时源码展开目录，
不参与构建，也不是运行依赖。QEMU 的 C 模型通过 `patches/0001..0019` 集成；
`recipes-devtools/qemu/qemu-system-native_%.bbappend` 引用同一组补丁。

## 构建与启动（Linux 构建机）

```sh
# 在 OpenBMC 构建环境中：构建固件和对应 native QEMU。
bitbake obmc-phosphor-image

# 或单独重建带本目录所有补丁的 QEMU。
sh meta-ctopai/meta-ceb-gnrd/tools/qemu/build-qemu.sh

# 启动镜像。
sh meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh
```

补丁目标为项目固定的 QEMU 11.0.2。独立构建安装到
`~/qemu-ceb-gnrd/qemu/bin/qemu-system-arm`，启动脚本优先选择它，
其次读取镜像 qemuboot.conf 中的 native QEMU，再回退 PATH。
可以用 `QEMU=/absolute/path/qemu-system-arm` 明确指定；启动时会打印选用的程序。
只有旧补丁的 QEMU 会提示缺少 0018，不能用于新增 eSPI/USB/CHASI# 检查。

| 环境变量 | 默认值 / 用途 |
|---|---|
| DEPLOY | ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd |
| STATE | ~/qemu-ceb-gnrd；QMP、FRU 文件、运行日志及面板上传的 VGA 图片 |
| BIOS_FLASH | ~/qemu-bios.bin，64 MiB BIOS 模拟 Flash |
| PANEL_PORT | 8800，模拟控制面板 HTTP 端口 |
| PANEL_WEB=1 | 强制使用浏览器控制面板 |
| NO_PANEL=1 | 隐藏面板，仍运行主机 COM1、USB、VGA 辅助线程 |
| NETWORK_CAPTURE=1 | 抓取管理网卡 Ethernet 包到 STATE/management.pcap，贯穿 BMC reboot |
| PECI_CPU=gnrd / spr | 默认 GNR-D 温度模型；spr 保留上一代 SPR 模型用于比较 |

Tk 面板需要 python3-tk；Tk 内嵌 JPEG 预览可安装 python3-pil.imagetk。
Web 面板使用 Python 标准库，不需要 Pillow。面板按功能分页，连接图独占页面，
不再把连接图和全部操作堆在同一竖向页面；小屏幕仍可能需要滚动。

## BMC Web 和模拟面板的访问

| 服务 | QEMU 所在机器上的地址 | 说明 |
|---|---|---|
| BMC Web / Redfish | https://127.0.0.1:8443 | 转发至 BMC eth0 192.168.185.200:443 |
| BMC SSH | 127.0.0.1:2222 | 转发至 BMC 22 |
| IPMI LAN | UDP 127.0.0.1:2623 | 转发至 BMC 623 |
| 模拟控制面板 | http://127.0.0.1:8800 | Python 主机模拟器，非 BMC Web |

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
现有 `ceb-gnrd-check` 包含写风扇、清日志等功能检查，不适合替代故障现场采集。

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

## CLI 与 QMP

`host-sim.py` 默认从 stdin 接收命令，`--gui` 打开面板，
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
