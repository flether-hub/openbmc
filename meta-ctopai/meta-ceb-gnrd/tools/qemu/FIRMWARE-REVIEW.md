# CEB-GNRD 静态审核与待验证事项

日期：2026-10-05。范围：板级 machine/DTS、recipe 集成及电源、按钮/LED、风扇、
传感器、PSU、网络、更新、健康恢复等关键链路；对相关上游实现做针对性核对。
这不是对整个上游 OpenBMC 所有源码的安全审计，也不代表全部板级代码均已运行验证。
quick-start、硬件合同、port_guide 是理解实现的辅助资料，运行行为以源码为准。

## 本轮有明确代码依据的固件修复

### 1. 风扇操作的共享目标竞态

文件：recipes-phosphor/fans/files/ceb-gnrd-fan-settings.py、
recipes-phosphor/webui/files/0003-ceb-gnrd-add-fan-control-page.patch。

原接口分“选风扇”和“设转速”，服务只有一个共享 selected。
两个网页客户端交错调用时会覆盖目标，可能将转速设到错误风扇。

修复：每个网页请求携带完整目标、模式、档位、保存选择，使用无参数 ApplyFan*
D-Bus 方法名编码参数；沿用 IPMI 的 SetFan 四参数接口。
同一个 asyncio.Lock 串行化配置写入、保存和后台恢复，
恢复任务在锁内重新读取文件，避免用户取消保存后仍使用旧状态。
后台对 Persist 的更新也移到锁内，避免锁外赋值覆盖新操作。
网页和风扇服务应一起构建部署，旧网页缓存需要刷新。

边界：这不是多条 D-Bus Properties.Set 的事务。写某个控制器后，后续写入失败，
仍可能留下部分配置；接口返回失败并记录日志。尚未增加跨服务回滚，
需要运行验证并评估实体管理器重配置时序。

### 2. CPU_MAX_TEMP / DIMM_MAX_TEMP 的 D-Bus 枚举异常

文件：recipes-phosphor/fans/files/ceb-gnrd-temp-max.py。

SensorObjectManager 接收的 threshold 对象列表被当作三元组解包，
GetManagedObjects / 全接口 GetAll 可能异常。IPMI 直接取属性能工作，
但依赖枚举的 Web/Redfish 路径失败。

修复：管理器 entries 存储实际 threshold 对象，
枚举时直接读取对象接口；报警事件循环保留自己使用的阈值元组。

仍需验证：ObjectManager 返回数据、Web 和 IPMI 同时显示两项温度，
阈值状态及主机断电后的不可用状态。

## 用户要求的日志调整

- systemd 的板级 sysctl 设置 kernel.printk=4 4 1 7，
  抑制普通 warning/info 串口输出，仍保留 error 及以上。
- PMBus “status register not found”改为 rate-limited warning，探测结果仍是 -ENODEV；
  未把不可访问电源视作正常设备。
- run-qemu.sh 把 QEMU stderr 放入 STATE/qemu.log；BMC UART 仍在终端。

这些是显示/频率策略，不能解决 PSU 通信故障和设备反复创建删除。
新 PMBus 补丁未在固定版本完整内核上构建验证；提交运行测试前应确认 do_patch 成功。
需要临时详细串口日志时，在 BMC 执行 dmesg -n 8。

## 重点待确认项

| 项目 | 代码依据 / 现象 | 当前结论与下一步 |
|---|---|---|
| UID 按键不点灯 | DTS V0 低有效输入、V1 高有效 LED；buttons/handler/LED group 三段链路 | 未确认归属。查 Released 信号、enclosure_identify.Asserted、LED brightness 和 GPIO 输出 |
| UID 启动顺序 | 固定版 button-handler 初始化时仅查询一次 ID object；buttons 请求 bus name 早于导出全部对象 | 存在服务启动竞态可能性，需 handler 注册日志及 D-Bus 对象证明；未修改固件 |
| GPIOI6 不切换 | owner 等待 FanCtrl zone 与六路 PWM/TACH，成功后保持 gpioset 并清除 reset tolerance | 低电平可能是门控未满足或 devmem 失败，不能仅凭面板判定 bug；查 owner journal、hwmon、zone |
| GNR-D PECI 支持 | 原 0003 将 GNR/GNR-D 套用 EMR；EDS-A 明确 4.2、八通道最高温度 | 已替换为独立 gnrd 配置，去掉继承的核心/阈值寄存器；0019 默认模拟 GNR-D；缺 MMIO 模式及真实板卡验证 |
| PSU 反复绑定 | 用户日志反复创建/删除 0x58..0x5a，QEMU 有 Unexpected stop、PMBus probe failure | 需核对 PSU detector 与 PSUSensor 的设备生命周期是否相互冲突，及 I2C 模型状态；非日志级别问题 |
| 电池 ADC | D3V0_BAT0 ScaleFactor=1；3 V 输入超过 2.5 V ADC 参考，下限阈值约 2.55 V | 电气/装配信息未确认；保持真实饱和模型，不能靠修改模拟读数掩盖 |
| BIOS 配置保留 | BIOS 更新选择整个 BIOS region，没有已确认的 UEFI variable store 子区域 | 不能据 FIT 外部分区认定保留 Setup；需 BIOS 团队给 variable store、FTW 和兼容迁移规则 |
| BIOS 更新并发电源操作 | 更新脚本先关机并切 SPI 所有权 | 需要确认升级期间其他电源操作和物理按钮是否被阻止；在未核实 CPLD/后端互锁前不直接判为已确认缺陷 |
| 更新失败/恢复 | BIOS SPI 所有权通过清理恢复，存在常规异常处理 | 断电、进程被强杀、写入途中 BMC 重启后的恢复仍需真实板卡/Flash 测试 |
| 健康服务自动重启 | bmcweb 等服务失败会触发 Quiesce 恢复，另有重启次数约束 | 服务异常可能被自动恢复覆盖；诊断应优先保存上一启动 journal 与 core metadata |
| 重启后 MAC 改变 | eth0 地址改变；Linux 从 chip 读取；ethaddr / eth1addr 均未配置；ping 网关恢复 Web | 按用户要求加入 U-Boot 固定默认地址；已有有效环境需补齐变量，仍需确认重启后地址及 Web 恢复 |

### 当前新增 Web 复现线索

用户报告：首次启动可访问，虚拟机内 reboot BMC 后构建机的 8443 TLS 超时。
故障时 BMC eth0=192.168.185.200/24、UP/LOWER_UP、路由正确；
本机 https://127.0.0.1/redfish/v1/ 完成 TLS 并返回 200，
到 QEMU 网关 192.168.185.1 的 ping 成功。
因此当前证据不支持修改 bmcweb；应先排查 QEMU 入站转发、MAC/ARP 及收发状态。
用户进一步确认仅 ping 网关即可恢复；重启前后的 MAC 从 2a:00:00:e0:d4:31
变为 56:65:f3:1a:b3:ae。固定 IP 配合变化的 MAC，且 QEMU 进程/网络后端未重启，
与保留的旧 ARP 映射在主机向网关发 ARP 后被更新的链路一致。
新日志显示 Linux 从芯片读取 eth0=56:65:f3:1a:b3:ae、eth1=52:54:00:12:34:58，
而 fw_printenv 显示 ethaddr、eth1addr 均未配置。因此 eth0 地址在 Linux 驱动读取前
已写入寄存器，最可能是缺少固定环境配置时 U-Boot 生成随机地址。
按用户要求，ceb-gnrd-env.h 新增 ethaddr=02:26:00:00:00:01、
eth1addr=02:26:00:00:00:02 默认值；不覆盖已有有效环境，不清空其他设置。
旧模拟镜像应在 BMC 中用 fw_setenv 补齐两项；真实板卡/并发实例需配置唯一地址。
尚未验证重启后实际地址与 Web 行为；未改 bmcweb、未用自动 ping 掩盖问题。
启动脚本新增可选 NETWORK_CAPTURE=1，抓取 management.pcap 辅助核对实际 ARP/目标 MAC。

## GNR / GNR-D 上游 PECI 核对（2026-10-05）

本轮可访问的 Linux master cputemp/dimmtemp 源码未包含 gnr 匹配项。
2026-09-28 邮件列表 v2 补丁新增 GNR CPU 识别、CPU/DIMM 温度支持，
但 CPU 匹配仅有 INTEL_GRANITERAPIDS_X，不能据此认定 GNR-D 已支持。
指定最新 release tag 的源码未能获取，未确认正式发布版本完整支持 GNR-D。

该 GNR 补丁使用 PECI revision 0x42，暂不实现 resolved cores mask，
DIMM 使用 12 channel ranks × 2 indexes，因 domain 访问限制不暴露 max/crit。
这与本项目原 0003 复制 EMR 寄存器、8 channel ranks 和 revision 0x40 的做法不同。
已读取用户提供的 GNR-D EDS-A 737226 rev 2.1.2，并重写 0003。
CPU 匹配分别使用 gnr / gnrd，温度协议版本为 0x42；GNR-D 的 PCS 14 为
八个通道，每个通道的最高 DIMM 温度同时出现在低两字节，不是两个独立 DIMM 温度。
驱动用一个 Channel N max 传感器表示一个通道，既有汇总服务直接取最大值。
GetTemp + PCS 16 路径用于 CPU 封装温度，不实现各 die 的核心掩码；
未就绪的零参考温度返回 -EAGAIN，已发现通道变为零返回 -ENODATA。
没有读取未经核实的 GNR-D DIMM 阈值寄存器；GNR-X 的 12 通道配置单独保留。

CPU 识别沿用内核 device.c 的 PCS 0 / 参数 0 签名解析，EDS-A 表 73 第 226 页
对此明确说明；固定版本 intel-family.h 定义 Family 6 / Model 0xAE 为 GNR-D。
真实板卡 CPUID 尚未采集；不能用模拟器写入的签名作为真实 CPU 证据。

用户授权先实现可确定路径，并假设 AMI BIOS 沿用上代的 PCS 14 测温方式。
实际 BIOS 模式待确认：第 236 页注 9 明确 PECI_UPDATE 模式读 PCS 14 返回全零，
需要另读 DIMMTEMPSTAT MMIO；现有 EDS-A 没给完整访问参数，未实现这条路径。
内核不可用时既有汇总服务在主机开机状态使用 90°C 失效保护值，不是实测 0°C。
固定内核 request.c 对 completion code 0x83 的专用重试尚未实现；EDS-A 第 225 页
说明它表示命令仍在进行。这是本轮未修改的传输层待办，需在真机观察并核对重试时序。
本轮对下载的固定源码进行补丁适用性核对，未编译或运行验证。

- [上游 cputemp 源码](https://raw.githubusercontent.com/torvalds/linux/master/drivers/hwmon/peci/cputemp.c)
- [上游 dimmtemp 源码](https://raw.githubusercontent.com/torvalds/linux/master/drivers/hwmon/peci/dimmtemp.c)
- [v2 CPU 识别补丁](https://lists.openwall.net/linux-kernel/2026/09/28/682)
- [v2 CPU 温度补丁](https://lists.openwall.net/linux-kernel/2026/09/28/710)
- [v2 DIMM 温度补丁](https://lists.openwall.net/linux-kernel/2026/09/28/692)

## 模拟器覆盖与限制

已整合 ADC 轨电压自动分压、CHASI#、eSPI 通道就绪/复位门控、
经 Peripheral 的 KCS/POST/COM1、VGA 输入及 USB host-side HID / 只读 SCSI 检查。
原有电源、风扇、PSU、温度、RTC、FRU 和 Flash 模型保留。
UID/风扇接管 LED 与 GPIO 状态取真实 BMC 输出，面板不代替 BMC 服务修改这些输出。

限制：未实现 eSPI 完整包传输/OOB/Flash、I3C/CPU SMBus 通信协议、
运行中的 x86 BIOS/OS、专用 RTL8211FS/E810 和精确电气时序。
Virtual Wire 当前覆盖 ready/boot/system-event 位，不能称为完整 VW 协议验证。
USB 覆盖 Linux vHub 常用 control/interrupt/bulk 路径，非完整 USB 主机控制器。
媒体读取通过 BMC gadget 和 backing file；挂载/弹出必须在 BMC Web 完成。
0019 将 PECI 默认型号改为 GNR-D，报告 4.2，并按通道最高值返回 PCS 14；
不再向 GNR-D 请求返回伪造的 SPR 核心掩码/阈值寄存器。仅模拟 root domain
的可确定温度路径，不包含域寻址、真实 BIOS CLTT 配置、MMIO 温度或异步完成码。

## 如何采集证据

- Web 故障：diagnose-web.sh host / bmc。
- UID、风扇接管、PSU、USB：把 diagnose-bmc.sh 放入 BMC，执行
  sh /tmp/diagnose-bmc.sh > /tmp/ceb-gnrd-diagnostics.txt。
- 脚本只读，不请求 GPIO、不切换 LED/PWM、不重启服务。
- 某些平台驱动或服务名不存在时会继续采集，输出中的 not found 需要结合 list-units 看实际名称。
- 运行验证由用户执行，本轮没有启动模拟器或部署镜像；
  不把静态语法/补丁检查作为硬件功能已验证的证据。
