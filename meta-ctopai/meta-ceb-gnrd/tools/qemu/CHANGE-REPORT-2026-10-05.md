# CEB-GNRD 改动与交付审核报告

日期：2026-10-05。供用户及其他 AI 对照源码审核。

## 1. 范围与交付状态

- 工作区：`D:\openbmc`，分支 `master`，基准 HEAD：`b245bc0a54d65f878d7a7e8be9229b96384b8275`。
- 本报告汇总当前未提交的固件修复、模拟器整合，以及本日重点完成的固定 MAC、GNR-D 温度驱动和 PECI 模型调整。部分 GUI/模拟器整合来自前面连续任务，不能将整个差异视为今天新写的代码。
- 正式模拟器入口、Python 模块和 QEMU 补丁均在 `meta-ctopai/meta-ceb-gnrd/tools/qemu`。`.tutorial-build` 只存下载源码、展开树、生成脚本和核对材料，正式运行不依赖该目录。
- 本轮未提交 Git、未部署、未执行 BitBake/C 编译、未启动 QEMU、未做功能测试。用户负责构建与运行验证。
- **代码已整合不等于全部任务完成。** UID、GPIOI6 的故障归属仍待运行证据；PECI 的 MMIO 模式、异步完成码处理及硬件兼容性仍有明确缺口。
- 设计目的：模拟 BMC 周边与 host 的交互，让真实 BMC 驱动/服务处理输入。GUI 不代替 BMC 点灯、修改风扇接管输出或直接挂载虚拟媒体。

以下路径除特别说明外均相对于 `meta-ctopai/meta-ceb-gnrd`。

## 2. 文件清单

### 已跟踪文件的修改

| 文件 | 用途及改动 |
|---|---|
| `recipes-bsp/u-boot/files/ceb-gnrd-env.h` | 增加开发实例的 `ethaddr` / `eth1addr` 默认值 |
| `recipes-core/systemd/systemd-conf_%.bbappend` | 安装板级控制台日志策略 |
| `recipes-devtools/qemu/qemu-system-native_%.bbappend` | 接入 QEMU 0018、0019，正式构建与独立构建共用补丁 |
| `recipes-kernel/linux/files/0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch` | 重写 GNR/GNR-D 温度支持，删除未经确认的旧代寄存器继承 |
| `recipes-kernel/linux/linux-aspeed_%.bbappend` | 接入 PMBus 日志补丁 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-settings.py` | 消除共享选中风扇竞态，串行化应用/保存/恢复 |
| `recipes-phosphor/fans/files/ceb-gnrd-temp-max.py` | 修复 ObjectManager 对阈值对象的枚举 |
| `recipes-phosphor/webui/files/0003-ceb-gnrd-add-fan-control-page.patch` | 网页每次操作使用包含完整目标的方法 |
| `tools/qemu/README.md` | 操作说明、接口覆盖、限制、MAC 迁移、GNR-D 模式 |
| `tools/qemu/host-sim.py` | GUI/CLI、ADC 电压换算、eSPI/KCS/COM1/USB/开盖控制 |
| `tools/qemu/panel.html` | Web 分页布局、VGA/USB 检查、ADC 统一 V、POST 倒序 |
| `tools/qemu/panel_tk.py` | 桌面面板布局及相同功能，连接图放独立页 |
| `tools/qemu/run-qemu.sh` | 模型接线、主机辅助进程、日志、可选抓包、PECI 型号选择 |

### 新增文件

| 文件 | 用途 |
|---|---|
| `recipes-core/systemd/files/50-ceb-gnrd-console.conf` | `kernel.printk=4 4 1 7` |
| `recipes-kernel/linux/files/0004-pmbus-ratelimit-optional-device-probe-message.patch` | PMBus 缺少 status register 信息改为限频 warning，探测失败仍失败 |
| `tools/qemu/FIRMWARE-REVIEW.md` | 固件审核依据、已修复问题、待确认项 |
| `tools/qemu/diagnose-bmc.sh` | BMC 侧只读采集按钮、LED、风扇、PSU、USB 等证据 |
| `tools/qemu/diagnose-web.sh` | 构建机/BMC 两侧只读 Web 与网络诊断 |
| `tools/qemu/host_io.py` | 带锁 QMP 访问、KCS 主机事务、USB 枚举/HID/只读 SCSI |
| `tools/qemu/panel_services.py` | VGA 图片校验及面板公共服务，不提供媒体挂载 API |
| `tools/qemu/patches/0018-aspeed-integrate-espi-usb-chassis-and-video.patch` | eSPI、USB、开盖、视频模型及 SoC 接线 |
| `tools/qemu/patches/0019-aspeed-peci-model-GNR-D-channel-temperatures.patch` | GNR-D PECI 4.2、PCS 14 通道最高温度模型 |
| `tools/qemu/CHANGE-REPORT-2026-10-05.md` | 本报告 |

`git diff` 不会显示未跟踪文件内容。审核时必须结合 `git status --short` 并读取上述新文件。

## 3. 固件侧已调整内容

### 3.1 风扇目标被并发客户端覆盖

原来服务共享 `selected`，客户端分两次调用“选风扇→设置”。两个客户端交错执行会把操作施加到错误风扇。

现在 Web 使用 `ApplyFan<目标><模式/档位><Keep|Forget>` 方法，方法名携带完整请求；保留 IPMI 的四参数 `SetFan(fan, mode, duty, persist)`。配置应用、保存和后台恢复由同一个 `asyncio.Lock` 串行化；恢复在锁内重新读取持久化状态，相关 Persist 更新也在锁内进行。

网页补丁与服务需要一起部署，浏览器旧缓存应刷新。这解决共享目标竞态，但多条 D-Bus 属性写入仍不是事务：后续写入失败可能留下部分配置，尚无跨服务回滚。

### 3.2 IPMI 能显示温度、Web 无法枚举

`SensorObjectManager` 接收到的是阈值对象列表，代码却按三元组解包。直接读取 Value 的 IPMI 路径可工作，而 ObjectManager / 全接口枚举可能失败。

修复后管理器直接枚举对象；报警循环保留自身所需的阈值元组。尚需用户确认 Redfish/Web、IPMI、阈值与断电行为。

### 3.3 控制台日志

- 板级 printk 策略抑制 warning/info/debug 的串口输出，error 及以上保留；日志仍可在 dmesg/journal 查询。
- PMBus `status register not found` 改为 `dev_warn_ratelimited`，返回值仍为 `-ENODEV`。
- QEMU stderr 写入 `$STATE/qemu.log`，BMC UART 仍在终端。

这些调整不会解决 PSU 反复创建/删除或 I2C 通信问题。PMBus 补丁还未在完整固定内核上构建。需要临时详细内核控制台输出可执行 `dmesg -n 8`。

### 3.4 BMC reboot 后 Web 失效与固定 MAC

用户提供的证据：BMC 本机 Redfish 返回 HTTP 200，IP/路由正确；构建机 8443 TLS 超时；BMC ping 网关后立即恢复。重启前后 eth0 MAC 分别为 `2a:00:00:e0:d4:31` 和 `56:65:f3:1a:b3:ae`。内核日志说明地址从芯片读取，`fw_printenv` 显示两项地址变量未定义。

固定 IP 配合变化的 MAC，与 QEMU 网络后端保留旧 ARP 映射、出站 ARP 更新后恢复的现象一致。随机地址最可能在 U-Boot 阶段产生，但未抓包确认全部因果链，也未核实随机地址生成的具体调用点。因此未修改 bmcweb、FTGMAC100 RX 代码或加入自动 ping。

按用户授权增加默认值：

```text
ethaddr=02:26:00:00:00:01
eth1addr=02:26:00:00:00:02
```

已有有效环境不会自动合并这些新默认值；常规固件更新还可能保留原 U-Boot。当前已确认缺变量的模拟实例可用 `fw_setenv` 补齐。真实板卡及并发实例应配置各自唯一地址。U-Boot 的 NC-SI 端口保持禁用，eth1 地址传到 Linux 的行为仍需核对。

## 4. GNR-D PECI：依据、实现与缺口

### 4.1 固定源码与 CPU ID 来源

项目 `meta-aspeed/recipes-kernel/linux/linux-aspeed_git.bb` 指定 Linux `6.18.53`，提交：

```text
c0538446e769fab620225578d378a0627b883bd5
```

该提交的 `arch/x86/include/asm/intel-family.h` 第 126、127 行已有：

```c
#define INTEL_GRANITERAPIDS_X IFM(6, 0xAD)
#define INTEL_GRANITERAPIDS_D IFM(6, 0xAE)
```

同文件第 43 行把 IFM 定义为 `VFM_MAKE(X86_VENDOR_INTEL, family, model)`。这两个符号来自内核，项目补丁只引用，未自行定义。它们编码 vendor/family/model，不编码 stepping，也不是 PECI 地址或命令号。

来源：[固定版本 intel-family.h](https://github.com/openbmc/linux/blob/c0538446e769fab620225578d378a0627b883bd5/arch/x86/include/asm/intel-family.h#L126)。本地下载副本为 `.tutorial-build/linux/peci-temperature/baseline/peci-intel-family-baseline.h`，便于核对。

识别沿用现有 PECI `device.c` 的 PCS index 0 / parameter 0 签名解析。用户提供的 Intel GNR-D EDS-A，文档 737226 rev 2.1.2，表 73、第 226 页确认该访问返回 CPUID。**内核有型号宏不代表温度驱动已支持该型号**；匹配表及读取逻辑是本次补丁的工作。

### 4.2 EDS 与上代参考的边界

| 依据 | 实现含义 |
|---|---|
| EDS-A 第 205 页，PECI revision 4.2 | GNR 配置最低 revision 为 `0x42` |
| 第 229 页 PCS 16；第 236 页参考温度就绪说明 | CPU 使用 GetTemp + 温度目标；零参考温度先返回 `-EAGAIN` |
| 第 230–231 页 PCS 14 | GNR-D 八通道，每通道低两字节重复最高温度；不是两条独立 DIMM 温度 |
| 第 236 页注 9 | PECI_UPDATE 模式 PCS 14 全零，需要 DIMMTEMPSTAT MMIO；目前未实现 |
| 第 225 页 CC `0x83` | 命令仍在进行，需要重试；固定内核请求层未覆盖，本轮未修改 |
| 2026-09-28 GNR v2 温度补丁 | 参考 GNR-X 的 4.2、跳过核心掩码、12×2 通道配置；不能直接当成 GNR-D 寄存器规范 |

上游参考：[CPU 匹配补丁](https://lists.openwall.net/linux-kernel/2026/09/28/682)、[CPU 温度补丁](https://lists.openwall.net/linux-kernel/2026/09/28/710)、[DIMM 温度补丁](https://lists.openwall.net/linux-kernel/2026/09/28/692)。

AMI BIOS 沿用 PCS 14 温度模式是用户提出的实施假设，未通过真实 BIOS 配置或板卡读数确认。EDS-B / Registers Specification 暂缺，不能补造 MMIO 地址。

### 4.3 内核 0003 的实际变化

相对固定上游三个源码文件为 **84 行增加、8 行删除**；不要与“相对仓库旧补丁的差异统计”混淆。

- `drivers/peci/cpu.c`：GNR-X 匹配 `gnr`，GNR-D 匹配独立 `gnrd`。
- `drivers/hwmon/peci/cputemp.c`：沿用封装温度转换；4.2 最低版本；没有可信核心掩码寄存器时不扫描核心；零 Tjmax 不缓存为正常值。
- `drivers/hwmon/peci/dimmtemp.c`：GNR-D 八通道、每通道一个 `Channel N max`；GNR-X 的 12×2 单独配置；不继承 EMR 的 DIMM 阈值寄存器；已发现的 GNR-D 通道后续读零返回 `-ENODATA`。
- 未实现 domain API、各核心温度、GNR-D MMIO 温度或主机热管理配置写入。

原有 `ceb-gnrd-temp-max.py` 扫描 PECI hwmon 并取最大值，可形成 `CPU_MAX_TEMP` / `DIMM_MAX_TEMP`。主机开机但读取失败时，现有服务使用 **90°C FAILSAFE_TEMP** 驱动保护策略；该值不是实测温度。主机断电时的既有替代行为也需要运行核对。

### 4.4 QEMU 0019

- 默认 CPUID 示例 `0x000a06e0`，Family 6 / Model AE，revision `0x42`。stepping 是模拟选择，不是真机采样。
- GNR-D PCS 14 返回八个通道最高值，低两字节重复；空通道返回零、越界返回 CC `0x90`。
- GNR-D 核心掩码和 Endpoint 寄存器请求返回不支持，不继续伪造 SPR 的寄存器成功回复。
- `PECI_CPU=gnrd|spr` 控制启动模式，默认 gnrd；旧 SPR 示例 `0x806f8` 保留用于比较。
- 启动参数使用 `-global driver=aspeed.peci,property=cpuid,value=...`，避免设备类型中的点被短格式错误解析。
- 此模型只覆盖已确定的 root-domain 温度路径，不模拟真实 BIOS 配置、domain 寻址、MMIO 温度或异步 CC `0x83`。

模型与驱动相互读通，仍不能证明二者均符合真实硬件。

## 5. 模拟器 0018 与 GUI 整合

### 5.1 eSPI 与串口/POST/KCS

eSPI 寄存器模型位于 `0x1e6ee000`、IRQ 42，提供 Peripheral/VW 就绪、复位、boot/system-event 位及错误 IRQ。主机 POST 80h、KCS3 ca2/ca3、COM1 经 Peripheral 路由和就绪检查；原生 POST 还等待 BMC boot wires。

COM1 通过双端 UART FIFO 接到真实 BMC VUART，而不是直接向串口 socket 注入文本；KCS 实现 IBF/OBF 主机握手，由实际 BMC 驱动/IPMI 服务生成回复。FIFO 满时限制 TX IRQ，减少空转。BMC reboot 不被误当作 host 断电。

这是寄存器及软件交互模型，未覆盖完整 eSPI 包协议、OOB/Flash、全部 VW、精确复位/电气时序。

### 5.2 KVM / USB / 虚拟媒体

- VGA 输入为 800×600 baseline 三分量 JPEG，最大 192 KiB，支持信号切换和视频完成中断。GUI 图片预览是 host 输入，实际捕获结果应在 BMC Web KVM 查看。
- USB vHub 位于 `0x1e6a0000`、IRQ 5，覆盖 control/interrupt/bulk、端点 ACK 与常用 DMA 路径。模型不是完整 USB 主机控制器，未实现 ISO 和所有错误恢复场景。
- 在 **BMC Web KVM** 发键盘/鼠标输入，GUI 接收真实 gadget HID 报告；文本解码只覆盖基本 boot keyboard 格式，其余保留原始报告。
- 在 **BMC Web** 挂载/弹出 ISO/IMG。GUI 只进行 host 侧枚举及 SCSI INQUIRY、READ CAPACITY、READ(10) 首扇区校验，显示容量和 LBA0 SHA-256，不直接挂载或写媒体。
- 读取结果是最近一次手动检查；换镜像需要重新检查。BOT 失败/STALL 后尚无完整自动 reset/sense 恢复，可能需“重新枚举”。

### 5.3 其他面板功能

- ADC 所有输入统一为 V，电源轨电压按 Entity Manager `ScaleFactor` 自动除算引脚电压，并显示分压和引脚电压。超过 ADC 参考范围仍饱和。
- CHASI# 提供开盖/合盖输入及 sticky latch，合盖不代替 BMC 清除事件。
- POST 历史新记录在前。
- 桌面采用分页面板，连接图独立页；移除全局竖向滚动布局。极小窗口下不承诺完全无需局部滚动。
- `NO_PANEL=1` 仍运行 host I/O 辅助流程；可选 `NETWORK_CAPTURE=1` 生成 management.pcap，默认关闭。
- 按用户最新要求未新增 RTL8211FS / E810 专用模型；保留现有网络实现。

## 6. 已做核对与未做验证

本表记录本轮已经完成的静态核对，不是功能测试结果。

| 项目 | 已完成范围 | 不代表什么 |
|---|---|---|
| Python | 六个正式模块的 AST 语法核对 | 未验证线程、D-Bus、实际 QMP 行为 |
| Web JS | 提取脚本并进行 Node 语法核对 | 未验证浏览器交互 |
| shell | build-qemu/run-qemu/两份诊断脚本语法核对；PECI 参数调整后重新核对启动脚本 | 未执行构建或启动 |
| 内核 0003 | 对固定提交下载的三份原始源码 `git apply --check` 通过 | 未验证完整 do_patch、编译或真实 CPU |
| QEMU 0018 | 对已有 0001–0017 后的相关展开源码核对适用性 | 未完成全量 QEMU 编译/启动 |
| QEMU 0019 | 对 QEMU v11.0.2 + 原 0007 PECI 文件核对适用性通过 | 未验证完整 19 补丁链构建 |
| Web/PMBus 补丁 | 补丁格式/numstat 可解析 | 未在完整依赖源码树应用构建 |
| 源文件空白 | 排除补丁容器的 `git diff --check` 通过 | 补丁内上下文空格必须保留，未当作普通源码删空白 |

未进行：C 编译、BitBake、QEMU 开机、并发客户端、KVM、USB、eSPI 复位、PECI/风扇/Redfish 联调、真实板卡测试。

## 7. 用户验证顺序

1. 构建包含内核、风扇服务及网页补丁的固件；另确保使用包含 0018/0019 的 QEMU。两个构建入口均引用正式目录中的补丁。
2. 当前缺 MAC 环境的模拟实例补齐 ethaddr/eth1addr；不要清空整个环境。重启后先从外部访问 Web，避免先 ping 刷新映射干扰判断，再比较重启前后两网口地址。
3. 开启 host，在 hwmon、IPMI、Redfish/Web 三处对照 CPU/DIMM 温度；读取失败时分清实测值与 90°C 保护值。
4. 两个 Web 客户端交错设置不同风扇，核对目标、保存/取消保存、服务恢复及失败返回。
5. BMC Web KVM 查看 VGA 图片；向 KVM 输入按键，核对面板 HID 报告。
6. BMC Web 挂载媒体，GUI 主机侧枚举及读取；弹出后重新检查。分别在主机断电、BMC reboot、USB reconnect 后观察行为。
7. eSPI 未就绪/复位时确认 POST、KCS、COM1 被阻断，恢复就绪后按实际服务状态继续；开盖事件也应由实际 BMC 服务处理。
8. UID/GPIOI6 不正常时运行只读诊断脚本回传，进一步确认固件还是模型问题。

操作入口和参数详见 [README.md](README.md)。独立构建脚本会重置其配置的 QEMU 源码目录，使用前应确认目录为专用构建树。

## 8. 尚未完成与风险

| 项目 | 当前状态 |
|---|---|
| UID 按键不点灯 | 尚无运行证据确认归属；按钮 handler 初始化存在可能竞态，未据此修改 |
| GPIOI6 风扇接管不变化 | owner 等待控制 zone 和六路 hwmon，需 journal/D-Bus/GPIO 证据 |
| PECI CC `0x83` | 请求层专用重试未实现，需规范时序和真机返回情况 |
| DIMMTEMPSTAT MMIO | 缺 Registers Specification，未实现 PECI_UPDATE 模式 |
| GNR-D 实际温度 | CPUID、4.2、AMI 模式、读数、不同板型/domain 待实板验证 |
| PSU 生命周期/通信 | 日志降级不是修复；创建删除冲突或模型状态需进一步定位 |
| D3V0_BAT0 | 当前 ScaleFactor=1，3V 超出 2.5V 参考；需电气/装配信息 |
| BIOS Setup 保留 | FIT 外部 BIOS region 无法定位 variable store/FTW；不能保证保留 |
| BIOS 更新互锁 | 升级期间电源操作、物理按钮、异常重启及 Flash 所有权恢复需核对 |
| I3C3 / CPU SMBus | 未模拟平台固件通信协议，不具备自动读取 BIOS 配置能力 |
| 模型覆盖 | 无运行中的 x86 BIOS/OS、精确电气时序、完整 eSPI/USB 或迁移状态支持 |

## 9. 给其他 AI 的审核指引

请先读取 quick-start、port_guide、README 和 FIRMWARE-REVIEW，再以源码为准审核。建议逐项回答“代码证据、问题严重性、最小修改、是否影响真实板卡”。

1. 固定内核源码上的 0003 是否编译；新增结构字段/数组边界/空回调是否兼容已有 CPU；八通道最高温度与 GNR-X 的 12×2 是否严格分开。
2. CPUID 解析和 IFM 来源是否一致；不要把模拟 CPUID 当作实板证明；核对 PECI version、PCS 16 零值、PCS 14 零值语义及 CC `0x83` 缺口。
3. 温度不可用时汇总服务的 90°C 是否满足风扇保护与对外可观测性要求，避免把替代值误称实测。
4. 风扇方法是否一次请求绑定完整目标；锁是否覆盖保存/恢复；部分 D-Bus 写失败的状态是否清楚；检查旧客户端兼容性。
5. QEMU 19 补丁顺序、Meson 接入、IRQ/寄存器/DMA 边界、USB 请求解析和 FIFO 行为是否符合实际 Linux 驱动使用合同。
6. eSPI readiness/reset 是否覆盖所有 host I/O 路由；BMC reboot 是否错误更改 host power；VW 覆盖是否被过度描述。
7. GUI 是否只操纵 host 输入并观察 BMC 输出；媒体是否实际走 BMC gadget；USB 读取是否只读且结果不会假冒当前挂载状态。
8. MAC 默认环境迁移与生产唯一地址是否清晰；Web 恢复是否有真实运行证据，避免引入固件自动 ping。
9. 所有未跟踪正式文件是否加入最终交付；`.tutorial-build` 是否仍只作临时材料；不要用静态核对结果替代用户构建/硬件验证。

**本报告与 FIRMWARE-REVIEW 均如实保留待办，不能作为“所有功能已通过验证”的交付证明。**

## 10. 提交记录（持续更新）

最后更新：2026-10-05。

- 2026-10-05 审核后提交：整合上文所有未提交改动并直接推送 master。审核结论：19 个 QEMU 补丁可按序应用到 QEMU v11.0.2，内核 0003/0004 对固定提交源码 `git apply --check` 通过；未构建、未运行。
- 同次修复：`meta-ctopai/quick-start.md` 中风扇网页调用说明改为单次 `ApplyFan<目标><模式><Keep|Forget>`；`run-qemu.sh` 不再用 `set --` 覆盖脚本参数，改用 `CAPTURE_ARGS`。
