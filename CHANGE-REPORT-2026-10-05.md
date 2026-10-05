# CEB-GNRD 变更报告（2026-10-05）

最后更新：2026-10-05 14:10 UTC（北京时间 22:10）

本文件记录每次提交的内容，供 Claude 不可用时由其他 AI 接着做。规则：

* 每次提交都在对应线程的章节里补充：改了什么、为什么、提交号、怎么验证、遗留问题，并更新上面的"最后更新"时间。
* 工作目录 `D:\openbmc` 被多个会话共用：改本文件前先 `git fetch` / `git pull`，提交时只 `git add` 自己的文件，不要用 `git add -A`。
* 本仓库的约定：直接提交到 `master`，不开分支、不开 PR；提交者 `flether-hub <flether@gmail.com>`，提交说明末尾加 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。
* 这台 Windows 电脑没有 C 编译器、没有 bitbake；所有补丁只用 `patch --dry-run` 验证能应用，没有编译，没有在板子上验证，除非下面写明。
* 在 Git Bash 里用 heredoc 写含反斜杠的 Python 会被改写，含 `\\n` 的替换请用 Write 工具写成脚本文件再运行。

---

## 一、线程「OpenBMC 固件 / FRU / 网页 / 传感器」（本线程）

仓库：`flether-hub/openbmc`，板子层 `meta-ctopai/meta-ceb-gnrd`（AST2600 BMC + Intel Xeon 6 GNR-D 主机）。
文档：`meta-ctopai/quick-start.md`（已合并原来的层 README，第九章是实现说明）、`meta-ctopai/port_guide.xlsx`。

### 1. FRU（`ipmitool fru print/write/gen`）

| 提交 | 内容 |
| :--- | :--- |
| `86e16c1a92` | 新增 `ceb-gnrd-fru` 软件包：`ceb-gnrd-fru-init`（空白 EEPROM 写入默认 FRU）、`ceb-gnrd-fru-rescan`（每次 `WriteFru` 之后 3 秒触发 `ReScan`）、`default-fru.bin`；删掉没用的 `ceb-gnrd-fru-present` 和 ipmi-fru-parser 写 EEPROM 补丁 |
| `bbf5b33a7f` | init 脚本的空白判断改成 BusyBox 能用的写法（`od -A` 不支持）；补零到 1 KiB 的做法已被 `4b6806250e` 取代 |
| `4b6806250e` | 根因修复：ipmid 的 Get FRU Inventory Area Info 返回已存镜像长度，`ipmitool` 把更大的镜像截断；改成报告 EEPROM 实际大小（读 sysfs）并用 0xFF 补到该大小（`recipes-phosphor/ipmi/files/0003-…patch`）；`fru-device` 的 `WriteFru` 上限从 512 放宽到 EEPROM 大小（`recipes-phosphor/configuration/entity-manager/0001-…patch`） |
| `37f66d991b` | phosphor-ipmi-fru 的旧 Write FRU Data 处理函数（只写 `/tmp/ipmifru00`）和我们的同优先级，靠加载顺序，结果旧的赢；把我们的 Get Area Info / Read / Write 三个处理函数注册到 `prioOemBase` |
| `821bf1250f` | `ipmitool fru gen`：一个字符的值类型/长度字节是 `0xC1`（和字段结束标记相同），补一个空格 |
| `922d93b2f7` | ipmid 的"写入是否到末尾"判断：ipmitool 按区域分块写，刚好写到最后一个区域起点的那次被当成镜像末尾，写出半新半旧的 FRU；改成最后区域长度已知后才判断。同时 `fru gen` 默认值改成 CTOPAI 板子值，空板默认镜像同步 |
| `0428fbd52d`、`412921ad24` | 默认值：Product 厂商 CTOPAI / 名称 CEB-GNR-D / 型号 93-XXXX-XX；Board FRU file ID 为 `0` |
| `63520a1889` | `fru gen` 在终端里把默认值放进输入行（可退格修改），非终端时回车保留默认、输入 `-` 表示空 |

验证：重新编译 `ipmitool`、`phosphor-host-ipmid`、`entity-manager`、`ceb-gnrd-fru` 后，BMC 里 `ipmitool fru gen`（一路回车）→ `fru write 0 fru.bin` → 等 5 秒 → `fru print 0`，应显示默认值。写入时应有 `Fru Size : 1024 bytes`。
遗留：`fru gen` 的新终端输入代码没有编译过；若 ipmitool 编译报错，修 `0001-ipmitool-fru-add-gen-command.patch`。

### 2. 传感器与 PECI

| 提交 | 内容 |
| :--- | :--- |
| `5153633a60` | 内核补丁 `0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch`：peci-cpu 驱动不认识 GNR（CPUID 0xAD/0xAE），照抄 Emerald Rapids 的表加上；`ceb-gnrd-temp-max` 改成直接读 `peci_cputemp` / `peci_dimmtemp` 的 hwmon，只发布 `CPU_MAX_TEMP`、`DIMM_MAX_TEMP`；不再构建 IntelCPUSensor，`ceb-gnrd.json` 删掉 `XeonCPU` |
| `a1cc889b1b`（另一线程提交，带上了本线程未提交的改动） | `ceb-gnrd-temp-max.py` 里加 ObjectManager（`/xyz/openbmc_project/sensors` 上的 `GetManagedObjects`）和主板关联（`Inventory.Item.Board`，当前是 `/xyz/openbmc_project/inventory/system/board/CEB_GNRD`） |
| `b245bc0a54` | bmcweb 读单个传感器用 `Properties.GetAll("")`（空接口名），dbus-fast 回答 NotSupported，Redfish 返回内部错误，网页丢掉这两个传感器；加消息处理函数回答 `GetAll("")` |
| `f6ca80160e` | PWM 传感器改名 `PWM0`–`PWM5`（`ceb-gnrd.json`、`ceb-gnrd-fan-settings.py` 里的路径） |

验证与现状：板上（QEMU 虚拟机）已确认映射器列出 44 个关联到主板的传感器，包含两个 MAX_TEMP，`GetManagedObjects` 返回正确；但网页仍是 42 项，原因是 `GetAll("")`，`b245bc0a54` 需要重新编译，或把新脚本拷到 `/usr/libexec/ceb-gnrd-temp-max.py` 后 `systemctl restart ceb-gnrd-temp-max` 临时试。试完用 `curl -sk -u root:0penBmc 'https://127.0.0.1:8443/redfish/v1/Chassis/CEB_GNRD/Sensors/temperature_CPU_MAX_TEMP'` 应返回 JSON。
遗留：GNR 的 PECI 寄存器表是照抄的，没有 Intel Xeon 6 PECI 文档，读数需要上板核对；板上用 `journalctl -u ceb-gnrd-temp-max` 看读到的来源。

### 3. GPIO 与 BMC 复位

* 结论（读内核源码，没有数据手册，没有上板验证）：AST2600 GPIO 每个引脚有 reset tolerance 位，内核在用户态（libgpiod、`gpioset`）申请一根线时自动置位，所以 `BMC_CPU_POWER_BUTTON`（GPIOV2）、`BMC_CPU_RESET`（GPIOV3）、`BMC_BIOS_FLASH_SELECT`（GPIOM1）在看门狗复位和用户触发的 BMC 复位中保持电平。寄存器：V2/V3 在 `0x1e78015c` 的 bit10/bit11，M1 在 `0x1e7800fc` 的 bit1，I6 在 `0x1e7800ac` 的 bit6。
* `6ad264c35d`：`BMC_FAN_BMC_OVERRIDE_N`（GPIOI6）必须在 BMC 复位时交还 CPLD，所以 `ceb-gnrd-fan-owner.sh` 占住这根线之后用 `devmem` 清掉它的 reset tolerance 位，清不掉就不接管风扇。遗留：BusyBox 有没有 `devmem` 没确认，没有就风扇永远留给 CPLD；板上要确认复位后这根脚悬空时 CPLD 真的接管风扇。
* `BMC_BIOS_FLASH_SELECT` 只在 BIOS 升级时改变，其他时间不碰，没有加开机释放服务。
* QEMU 模拟：`92c6702e07`、`679015d7df` 在 `host-sim.py` 里保持 BMC 复位期间的电平、没人驱动时电源键/复位显示为高（板上上拉）。这部分文件由「QEMU 讨论串」维护，那边在 `4a131bf841` 里做了同样的事，以那边为准。

### 4. 网页（webui-vue 补丁，`recipes-phosphor/webui/files/`，在 `webui-vue_%.bbappend` 里登记）

| 补丁 | 提交 | 内容 |
| :--- | :--- | :--- |
| `0016-ceb-gnrd-post-codes-newest-first.patch` | `fddb2f60d2`、`71ee34f2ab`、`eb73d3bce9` | POST Code 最新的在前：表格按 `id` 倒序，但条目没有 `id`；现在按时间排，同一秒内按服务返回顺序靠后的在前（bmcweb 是最新一次启动在前、每次启动内旧的在前） |
| `0017-ceb-gnrd-sensors-pagination.patch` | `a91ed50ad5` | 模拟量传感器表分页（每页 20 条，可选 10/20/30/40/查看全部），去掉固定高度 |
| `0018-ceb-gnrd-firmware-progress-survives-page-change.patch` | `9cce0ee99f` | 升级过程中切换页面再回来，进度条保留：运行状态存 `sessionStorage`（BIOS 存升级任务地址，BMC 存等待重启的起点），回来时继续轮询；上传阶段离开页面无法恢复 |
| `0019-ceb-gnrd-factory-reset-bmc-wording.patch`、`files/zh-CN.json` | （见下方提交号） | 恢复出厂设置页只重置 BMC，去掉和服务器有关的说明：标题/按钮/成功失败提示不再写"BMC 和服务器设置"，去掉"分区配置和平台密钥库可能被恢复"一项，去掉"没有关闭系统会出现不可恢复错误"的警告和"继续执行且不关闭系统"勾选框（弹窗确认不再要求勾选）；中文提示同步 |

验证：补丁都在锁定的 webui-vue `8538dca1`（先套用前面的补丁）上 `patch --dry-run` 通过，`0017`、`0018` 本机跑过 `eslint` 和 `vite build`（构建树在 `C:\Users\nini_\AppData\Local\Temp\claude\D--openbmc\<会话>\scratchpad\wv`）。没有在真实网页上看过。

### 5. 设置

* `eb73d3bce9`（用 `sed` 改原生配方的默认值，板上测下来没有生效：`/var/lib/phosphor-settings-manager` 不存在，说明没有保存值，运行时默认值仍是 AlwaysOff；`98e5c97e5f` 之后的提交已改成标准做法，见本条末尾）：电源恢复策略出厂默认值改成 `AlwaysOn`（来电开机）。已经保存过策略的 BMC 不受影响，要在网页里手动选一次或恢复出厂。最近一次截图里网页仍显示 Always off，原因未确认：可能是保存的旧值，也可能是镜像没有重编；在 BMC 里用 `busctl get-property xyz.openbmc_project.Settings /xyz/openbmc_project/control/host0/power_restore_policy xyz.openbmc_project.Control.Power.RestorePolicy PowerRestorePolicy` 看。

* **改法（标准做法）**：删掉 `phosphor-settings-defaults-native.bbappend`，改在 `phosphor-settings-manager/settings.override.yml`（和 SOL 的覆盖同一个文件，已知有效）里覆盖 `/xyz/openbmc_project/control/host0/power_restore_policy`，`PowerRestorePolicy` 默认 `AlwaysOn`，`PowerRestoreDelay` 默认 0（合并脚本会整个替换列表，所以延迟也要写）。用 `merge_settings.py` 在本机合并上游模板验证过结果正确，没有编译。验证：新镜像第一次启动（没有保存过设置）后 `busctl get-property xyz.openbmc_project.Settings /xyz/openbmc_project/control/host0/power_restore_policy xyz.openbmc_project.Control.Power.RestorePolicy PowerRestorePolicy` 应为 `AlwaysOn`。

### 6. 仓库整理与文档

* `0556911a7e`：`quick-start.md`、`port_guide.xlsx` 移到 `meta-ctopai/`；`meta-ceb-gnrd/README.md` 合并进 `quick-start.md` 第九章并删除。
* `420a3073be`：删掉教程中间脚本（`port_guide_edit.mjs`、`.inspect.ndjson`、`.tutorial-build/` 等）。`artifacts/` 已按用户要求删除（没有被 git 跟踪，无法恢复）。
* `f7aa9a40d5`、`32b1c85dfa`：`.gitignore` 更新。
* `a79856abea`：根目录加符号链接 `run-qemu.sh`。
* 遗留：`meta-ctopai/openbmc-tutorial.md/.pdf`、`quick-start.pdf`（已过期）没有删，等用户决定；`meta-ctopai/README.md` 曾在工作区显示为已删除，已随 `5153633a60` 一起提交了删除，不是有意的，用户没有回复要不要恢复。

### 7. 开放问题汇总（下一个 AI 先看这里）

1. 网页传感器页要出现 `CPU_MAX_TEMP`、`DIMM_MAX_TEMP`：需要带 `b245bc0a54` 的镜像，或按第 2 节的办法临时替换脚本。
2. 电源恢复策略默认值是否生效（见第 5 节）。
3. FRU 全流程要在重新编译后的镜像上验证一遍（第 1 节）。
4. `ceb-gnrd-fan-owner` 依赖 `devmem`，需确认镜像里有。
5. GNR 的 PECI 表是抄的，上板验证读数。
6. POST Code 倒序在真实页面上的效果。
7. 用户尚未回答的决定：是否删除 `meta-ctopai/openbmc-tutorial.*`、`quick-start.pdf`；是否恢复 `meta-ctopai/README.md`；`ceb-gnrd-ipmi-fru-read-inventory-native.bb` 是否可删。

---

## 二、其他线程

### 线程「QEMU 模拟器 / 控制面板」

约定：直接提交到 `master`，不建分支；固件在用户的 Ubuntu x86 构建机上编译，写这些改动的机器（Windows）没有编译器，凡写「未验证」的都没编译过。

基础信息
- 运行：仓库根目录 `./run-qemu.sh`（链接到 `meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh`）。BMC 登录 `ssh -p 2222 root@127.0.0.1`，密码 `0penBmc`；网页 https://127.0.0.1:8443。
- QEMU 板级模型是 `tools/qemu/patches/NNNN-*.patch`（基于 QEMU 11.0.2，即当前 OE-core 的版本），由 `recipes-devtools/qemu/qemu-system-native_%.bbappend` 打到 `qemu-system-native` 上。新增补丁必须加进该文件的 `SRC_URI`，且补丁里要有 `Upstream-Status:` 行，否则 `do_patch` 报错。`tools/qemu/build-qemu.sh` 可在 Yocto 之外编同一个 QEMU。
- 面板：`tools/qemu/host-sim.py --gui`，有显示用 Tk 窗口（`panel_tk.py`，需 `python3-tk`），否则网页（`panel.html`，端口 8800）。`tools/qemu/README.md` 有完整说明和补丁清单。

只改模拟器、不改 BMC 固件的提交
| 提交 | 内容 / 原因 | 验证 |
|---|---|---|
| `5495773654` `e3027dd9b2` `e6abc1e72d` | 补丁 0001-0012：AHB 时钟、PWM/TACH 风扇、`bmc-host-sim`（GPIO 上的主机上电时序、POST 码）、可设 ADC、GPIO 复位保持、`crps-psu`、PECI 上的 CPU、`nct3018y` RTC、VUART 和 LPC snoop、面板用只读属性 | 能编过；`./run-qemu.sh`；面板有风扇、PSU、POST 码 |
| `4457decde3` `335ebdf791` | Tk 面板窗口（网页作后备）、滚动条 | 面板能打开、能滚动 |
| `518c8934d7` | 每个补丁加 `Upstream-Status`（Yocto QA 让 `do_patch` 失败） | `do_patch` 通过 |
| `4147d44053` | 补丁 0013：引脚切成输出时驱动最后写入的电平（LED 显示旧电平） | 面板 UID/告警灯跟随 |
| `dbe0abe1aa` `a25b7bed32` | 补丁 0014/0016：AST2600 视频引擎，给 BMC KVM 一张 800x600 静态画面（`tools/qemu/kvm/post.jpg`、`os.jpg`），画面出现时发模式检测中断 | 主机开机后网页 KVM 出画面。**用户还没确认** |
| `4a131bf841` | 补丁 0015 `gpio-dir[N]`；面板把 BMC 没驱动的输出线按板上上拉/下拉显示 | BMC 启动后复位/电源线是绿色 |
| `6c61c648b8` | `run-qemu.sh` 的 `-global` 要写成 `driver=aspeed.adc,property=chN-mv,value=…`（简写会在第一个点处被切开）；补丁 0017：补偿模式所有通道都读半量程，驱动偏移为 0 | ADC 读数是额定电压，只剩 D3V0_BAT0 告警 |

模拟器暴露出的固件问题（真板上同样存在）
| 提交 | 内容 / 原因 | 验证 |
|---|---|---|
| `c9984be953` | DTS 加 `pwm-fan0..5` 和 `CONFIG_SENSORS_PWM_FAN`；`aspeed-g6-pwm-tach` 只注册 pwmchip，fansensor 报 "no pwm channel found" | `ls /sys/class/hwmon/*/pwm1` 有 6 个 |
| `a1cc889b1b` | `ceb-gnrd-fan-owner.sh` 只认 `fanN_input` 旁边的 `pwmN`，改为也认 `pwm-fanN` 的 `pwm1`；否则 `BMC_FAN_BMC_OVERRIDE_N` 永远不拉高 | `gpioinfo` 里该线 `[used]`。**用户反馈线仍是低，等 `journalctl -u ceb-gnrd-fan-owner` 输出** |
| `4147d44053` | `ceb-gnrd-psu-detect.sh`：PSU 插拔后重启 psusensor，轮询 10 s、2 次不应答算拔出 | 面板插入 PSU2，约 10 s 内出现 PSU2_* sensor |
| `36a47cd3bf` | `recipes-phosphor/images/obmc-phosphor-image.bbappend`：打包任务等 `linux-yocto-fitimage:do_deploy`（清 sstate 后 "image-kernel: No such file"） | 干净构建能打包 |
| `77a8624030` | `gpio_defs.json` 里 UID 按键名改成 `ID_BTN`（phosphor-buttons 只认这个名字） | `gpioinfo` 里 `BMC_UID_BUTTON_N` `[used]`，按键切换 identify 灯。**用户反馈：先能亮，重编后不亮，等 `gpioinfo`、`gpio_defs.json`、`gpiomon` 输出** |
| `d37433c2d8` | `ceb-gnrd-alert-led.py`：入侵状态是完整枚举串，比较最后一段（否则每次启动都误记一条入侵 SEL） | 启动日志没有 "Chassis intrusion detected" |
| `6e5868b21b` | `ceb-gnrd-alert-led.py`：`mapper_sensors()` 把结果变成元组又要求列表，找不到 sensor，电压告警从不点亮告警灯 | D3V0_BAT0 告警 → 告警灯红 |
| `44c7124c6a` | UID 按键重启后不亮：`phosphor-button-handler` 只在启动时查一次 UID 按键对象，而 `buttons` 守护进程先占总线名、后导出对象，两者同时启动就竞争，handler 忽略 UID 键（手工重启两个服务后又能亮，和现象一致）。给 handler 加 systemd drop-in，先等 `Buttons/ID` 对象出现（`ceb-gnrd-wait-buttons.sh`，最多 60 s，不阻塞）。**未编译验证** | 重启 BMC 后 `journalctl -u phosphor-button-handler` 应有 "Registering ID button handler"；按 UID 键灯切换 |
| `680aa17b1f` | **UID 按键不亮的真正原因**：`x86-power-control` 和 `phosphor-buttons` 都请求总线名 `xyz.openbmc_project.Chassis.Buttons`，谁先起谁拥有；`x86-power-control` 抢到时 `phosphor-buttons` 的对象（含 `Buttons/ID`）根本不可达，handler 看不到 UID 键（`busctl tree …Chassis.Buttons` 里只有 state/control 对象；`gpioinfo` 里 `BMC_UID_BUTTON_N` 被 "sysfs" 占着；前一个 `44c7124c6a` 的等待脚本因此白等 60 s）。新增 x86-power-control 补丁 `0002-ceb-gnrd-own-bus-name-for-the-exported-buttons.patch`，把它导出的按键换成自己的总线名 `com.ctopai.CebGnrd.PowerControl.Buttons`。**未编译验证**（补丁已对固定版本源码做过 `patch --dry-run`） | 重编重启后 `busctl tree xyz.openbmc_project.Chassis.Buttons` 里有 `Chassis/Buttons/ID`；handler 日志有 "Registering ID button handler"；按 UID 键灯切换 |
| `dc7bf2af9b` | 面板事件日志加详细：每次轮询对比状态，记录 GPIO 信号跃变（含方向和低有效含义）、温度、风扇故障/固定/转速、PSU 插拔/AC/功率/温度、PECI、ADC（引脚 mV 和电源轨 V）、RTC 电池、机箱、eSPI、USB HID 报告、VGA 信号/图片、POST 码。VGA 预览改用 Pillow 解码成 PPM 交给 Tk（原来要 `python3-pil.imagetk`，缺包时预览显示不出来，现在只需 `python3-pil`，缺包或出错会在预览处写原因）。Tk 面板窗口生效，网页面板的日志也显示这些行。**未在真实 QEMU 上验证** | 面板「事件日志」里操作后出现对应行；VGA 页选图后显示 400×300 预览 |
| _(本提交)_ | 补丁 0020：ADC 通道值保持 10 位。测试斜坡给高半字加 7 时没有屏蔽，可能把第 26 位置 1；之后该通道设了电压，这个多余的位还留着，读回 2047（11 位），驱动换算成约 2 倍参考电压（D3V0_BAT0 显示 4.997 V，`in_voltage7_raw` 实测 2047）。斜坡加屏蔽，设电压前清掉多余位。**未编译验证** | 重编后 `cat /sys/bus/iio/devices/iio:device1/in_voltage7_raw` ≤ 1023；D3V0_BAT0 读 ≤ 2.5 V |
| `bb902c5133` | Entity-Manager ADC 的 `ScaleFactor` 写反了：dbus-sensors 是 `(raw/1000)/ScaleFactor`，即 ScaleFactor 是除数，分压比 10K/1K 应写 1/11（0.090909）、2:1 写 0.5；原来写 11 和 2，读数变成引脚电压再除以 11（12 V 轨显示 0.099 V，3.3 V 轨显示 0.824 V），所有分压通道都报 Critical。已把 11→0.090909、2→0.5。模拟器的 ÷N 分压没有问题。**真板同样受影响；未编译验证** | 设 12.1 V 后网页读 12.1 V；只剩 D3V0_BAT0 告警 |
| _(本提交)_ | 面板「硬件连接」页下方大片空白：窗口高度改为 760，示意图只占自身高度（行距上限 34）。`ceb-gnrd-fan-owner.sh` 失败时打印缺哪一项（风扇 zone 是否出现、最后缺的是哪个 hwmon/pwm/tach），便于定位 override 线不拉高的原因。注意：脚本装在 `/usr/sbin/ceb-gnrd-fan-owner`，不是 `/usr/libexec/`。**未验证** | 面板下方不再空白；fan-owner 失败日志有 "fan-control zone found: …" 一行 |

开放问题（QEMU 线程）
1. UID 灯重编后不亮、风扇 override 线仍低：见上面两行「等输出」。
2. KVM 画面（补丁 0014/0016）在真实 QEMU 构建上没验证。
3. D3V0_BAT0 额定 3.0 V、ScaleFactor 1，超过 ADC 2.5 V 参考电压，永远读 2.5 V 并告警；需对照原理图加分压（如 2:1，ScaleFactor 0.5）。其他通道的 ScaleFactor 已改成 1/分压比。
4. KVM 的 USB 键鼠输入（aspeed-vhub）没做，工作量约视频引擎的 3 倍；PCIe/USB 画面和 PCIe 插拔也没做（已询问，未答复）。
5. 提过但没做：主机侧 KCS（带内 IPMI）、机箱入侵模型、用真实 x86 QEMU 当主机、MCTP/PLDM、BIOS 升级流程。
6. 「ADC 填测量值 V、分压由模拟器自动处理」的面板改动由另一个线程在做（写本节时在工作区未提交）。

### 审核并整合提交（审核线程）

`804b1ed653` 提交了此前工作区里未提交的 23 个文件（GNR-D PECI、风扇 ApplyFan 方法、QEMU 0018/0019、模拟器 GUI/host I/O 等，详见 `meta-ctopai/meta-ceb-gnrd/tools/qemu/CHANGE-REPORT-2026-10-05.md`）。审核结论：19 个 QEMU 补丁可顺序应用到 v11.0.2，内核 0003/0004 对固定提交源码 `git apply --check` 通过；未构建、未运行。同时修了 `quick-start.md` 里过时的风扇网页调用说明和 `run-qemu.sh` 的 `set --`。该提交用了 `git add -A meta-ctopai`。

### 线程「把 CEB-GNRD 展开到 .tutorial-build」

* `d9fe2246a7`：新增 `meta-ctopai/meta-ceb-gnrd/tools/expand-to-tutorial-build.py`。`.tutorial-build/` 是被 git 忽略的临时源码展开目录（见 `tools/qemu/README.md`），此前只放了 QEMU/PECI 的 base/tree 展开。用户要求 CEB-GNRD 相关代码能展开到这里，取最小改动的理解：把层本身和它依赖的仓库内文件按原目录结构复制过去。
  * 复制内容：`meta-ctopai/meta-ceb-gnrd`、`meta-ctopai/conf`（`layer.conf`、`ctopai-openbmc` distro，bblayers 模板同时引用这两个层）、`meta-ctopai/quick-start.md`（第九章是本层说明）。只复制 git 跟踪的文件，取工作区内容（未提交的修改会带上，未跟踪的临时文件不会）。
  * 目标默认 `.tutorial-build/ceb-gnrd/`，每次运行先删掉该目录再复制，`.tutorial-build/` 下其他内容不动；可传参数指定其他目标，但拒绝写到仓库内 `.tutorial-build` 以外的位置。
  * 不包括：上游源码（QEMU、内核、webui-vue 等）的 base/tree 展开和打补丁，那需要联网取固定版本源码，没做。
  * 验证：`python3 meta-ctopai/meta-ceb-gnrd/tools/expand-to-tutorial-build.py` 输出 `N files -> ...\.tutorial-build\ceb-gnrd`；`diff -r meta-ctopai/meta-ceb-gnrd .tutorial-build/ceb-gnrd/meta-ctopai/meta-ceb-gnrd` 无差异。已在本机运行两次（第二次覆盖），193 个文件，diff 一致。
* `990db41c7e`：用户说原来的子目录不合理可以自行处理，于是整理了 `.tutorial-build/`（本地目录，不在 git 里）：`ceb-gnrd/`（层的副本）、`qemu/kvm-usb/`（补丁 0018 的 base/tree、`export_integration.py`，零散下载文件放 `ref/`）、`qemu/peci-sim/`（补丁 0019 的 base/tree 和生成脚本）、`linux/peci-temperature/`（内核补丁 0003 的 base/tree、固定版本 `baseline/` 和生成脚本）、`eds/`（GNR-D EDS PDF、文本和提取脚本）、`scripts/`。改了各生成脚本里的路径（`export_integration.py` 去掉硬编码 `D:/openbmc`，改为相对路径），并在 `.tutorial-build/README.md` 和展开脚本的说明里写明布局；`tools/qemu/README.md` 和 `tools/qemu/CHANGE-REPORT-2026-10-05.md` 里两处旧路径已更新。`kvm-usb/tree` 被占用无法改名，用复制后 `diff -r` 一致再删除原目录。
  * 验证：在新位置运行三个生成脚本（`qemu/peci-sim/build_gnrd_peci_sim_patch.py`、`linux/peci-temperature/build_gnrd_temperature_patch.py`、`qemu/kvm-usb/export_integration.py`），重新生成的补丁 0019、内核 0003、0018 与已提交版本逐字节一致（`git status` 无变化）。`qemu/kvm-usb/revise_media.py` 是一次性改仓库文件的脚本，没有运行。
