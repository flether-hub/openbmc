# CEB-GNRD 变更报告（2026-10-05）

最后更新：2026-10-05 11:56 UTC（北京时间 19:56）

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

验证：补丁都在锁定的 webui-vue `8538dca1`（先套用前面的补丁）上 `patch --dry-run` 通过，`0017`、`0018` 本机跑过 `eslint` 和 `vite build`（构建树在 `C:\Users\nini_\AppData\Local\Temp\claude\D--openbmc\<会话>\scratchpad\wv`）。没有在真实网页上看过。

### 5. 设置

* `eb73d3bce9`：电源恢复策略出厂默认值改成 `AlwaysOn`（来电开机），在 `phosphor-settings-defaults-native.bbappend`。已经保存过策略的 BMC 不受影响，要在网页里手动选一次或恢复出厂。最近一次截图里网页仍显示 Always off，原因未确认：可能是保存的旧值，也可能是镜像没有重编；在 BMC 里用 `busctl get-property xyz.openbmc_project.Settings /xyz/openbmc_project/control/host0/power_restore_policy xyz.openbmc_project.Control.Power.RestorePolicy PowerRestorePolicy` 看。

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

（QEMU 模拟器线程请在此补充：`tools/qemu/`、QEMU 补丁、面板、KVM 画面、PWM/TACH 等。）
