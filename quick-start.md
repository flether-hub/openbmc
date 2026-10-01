# CEB-GNRD OpenBMC 快速上手与开发指南 (Quick Start Guide)

本文档详细说明如何从零开始构建 `ceb-gnrd` 固件镜像，如何在 QEMU 模拟器中启动并测试 WebUI/SSH/Redfish，以及如何遵循 OpenBMC 开发规范、使用 `devtool` 进行源码修改、新增代码与板级 Patch 产出。

> **硬件平台说明**：
> 本项目面向 **Intel Xeon 6** 单路主板平台，BMC 芯片为 **ASPEED AST2600**。
> QEMU 模拟环境主要用于验证 OpenBMC 用户空间、`bmcweb`、WebUI 前端、SSH、网络配置及核心 D-Bus 接口流程，不能替代真实硬件环境中的 eSPI、PECI、ADC、PMBus、PWM/TACH 和实体网口测试。

---

## 📚 参考资料与推荐教程

* **官方/社区核心教程**：[Home | OpenBMC Guide Tutorial](https://michaeltien8901.github.io/openbmc-guide-tutorial/)
* **OpenBMC 官方文档**：[OpenBMC Documentation](https://github.com/openbmc/docs)
* **Yocto Devtool 官方参考手册**：[Yocto Application Development and the Extensible SDK](https://docs.yoctoproject.org/sdk-manual/extensible.html)
* **OpenBMC WebUI 前端仓库**：[webui-vue](https://github.com/openbmc/webui-vue)

---

## 一、OpenBMC 开发与分层规范原则

在 OpenBMC 开发中，严格遵循分层隔离与代码收敛原则，能确保后续平滑同步社区上游更新：

1. **板级目录隔离原则（Board-Level Layering）**：
   * **严禁直接修改上游图层**（如 `upstream-layers/openembedded-core`、`meta-phosphor`、`meta-aspeed`、`meta-openembedded` 等）。
   * 所有针对本板卡的修改（设备树 DTS、Entity-Manager JSON、IPMI YAML、systemd 网卡配置、自定义服务脚本、上游软件功能补丁）**必须全部集中收敛在板卡级目录**：`meta-ctopai/meta-ceb-gnrd/`。

2. **Patch 与 bbappend 管理规范**：
   * 对任何开源组件（如 Linux 内核、`bmcweb`、`webui-vue`、`dbus-sensors` 等）的修改与新增代码，均应通过**板卡层中的 `.bbappend` + `.patch` 补丁**方式引入。
   * 补丁文件存放在对应配方目录的 `files/` 下，使用 `SRC_URI:append` 引入。
   * 补丁必须具备清晰的 Git Commit Title、功能说明和 `Signed-off-by` 签名。

3. **配置与接口解耦（D-Bus / Redfish 标准化）**：
   * 硬件拓扑与传感器接入优先通过 Entity-Manager JSON 配置，利用 `dbus-sensors` 自动加载，避免在底层驱动或服务中硬编码物理 I2C 地址。

---

## 二、构建环境与完整依赖准备

以下命令应在 Linux 主机或虚拟机中执行（推荐使用 **Ubuntu 22.04 LTS / 24.04 LTS**）。

### 1. 安装 OpenBMC / Yocto / QEMU 全套依赖

原生的 Yocto 基础包仅涵盖通用编译工具，进行 OpenBMC 开发、测试和模拟器验证还需要补充 **QEMU ARM 模拟器**、**IPMI 测试工具**、**Redfish/JSON 解析工具** 以及 **Python YAML/打包库**。

请直接运行以下一键安装命令：

```bash
sudo apt update
sudo apt install -y \
    build-essential chrpath diffstat gawk git wget curl \
    libegl1-mesa libsdl1.2-dev python3 python3-git \
    python3-jinja2 python3-pexpect python3-subunit python3-pip \
    python3-yaml python3-setuptools socat texinfo unzip xterm \
    zstd lz4 cpio file locales libssl-dev jq ipmitool \
    qemu-system-arm qemu-utils openssh-client
```

#### 📦 关键依赖分类说明：
* **Yocto / BitBake 核心构建依赖**：`build-essential`、`diffstat`、`gawk`、`chrpath`、`texinfo`、`zstd`、`lz4`、`cpio`、`file`、`socat`、`unzip`
* **Python 开发与 YAML 解析库**：`python3-pip`、`python3-yaml`（处理 IPMI/Entity-Manager YAML 配置）、`python3-jinja2`、`python3-git`
* **QEMU 模拟与固件运行工具**：`qemu-system-arm`（运行 AST2600 模拟器必选）、`qemu-utils`
* **BMC 联调与测试工具**：`ipmitool`（执行 IPMI 指令/读写 FRU/传感器）、`curl` & `jq`（测试与格式化 Redfish API 返回的 JSON 数据）、`openssh-client`（SSH 登录）

### 2. 设置 UTF-8 语言环境

```bash
sudo locale-gen en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

---

## 三、从零开始构建 ceb-gnrd

### 1. 获取并初始化源码仓库

```bash
git clone https://github.com/flether-hub/openbmc.git openbmc
cd openbmc
git submodule update --init --recursive
```

确认板级层结构完整：
```bash
test -f meta-ctopai/meta-ceb-gnrd/conf/machine/ceb-gnrd.conf && \
    echo "ceb-gnrd machine layer found"
```

### 2. 初始化构建环境与配置

在 OpenBMC 开发中，通常有两种初始化环境的方式：

#### 方式 A：使用 `. setup ceb-gnrd`（推荐：用于全新创建与初始化）
```bash
cd ~/openbmc
. setup ceb-gnrd
```
* **作用**：OpenBMC 定制的引导配置脚本。它会自动创建 `build/ceb-gnrd` 目录，生成包含正确板卡配置的 `conf/local.conf`（自动注入 `MACHINE = "ceb-gnrd"`）以及完整的 `conf/bblayers.conf` 图层配置，并自动切换当前 Shell 至构建目录。
* **适用场景**：**首次构建**、**全新创建构建目录**或需要重新生成标准构建配置时使用。

#### 方式 B：使用 `source oe-init-build-env build/ceb-gnrd`（用于日常进入已有环境）
```bash
cd ~/openbmc
source oe-init-build-env build/ceb-gnrd
```
* **作用**：OpenEmbedded / Yocto 原生环境加载脚本。它主要负责配置当前 Shell 的 `PATH`、`BUILDDIR` 等 BitBake 运行时环境变量，并将工作路径切入 `build/ceb-gnrd`。它直接复用已有的配置文件，不会重新覆写。
* **适用场景**：**日常开发**、**新开终端窗口**或**重新登录后继续编译已有构建目录**时使用。

#### 💡 两者核心区别对比速查

| 对比项 | `. setup ceb-gnrd` | `source oe-init-build-env build/ceb-gnrd` |
| :--- | :--- | :--- |
| **功能定位** | OpenBMC 定制的一键初始化脚本 | Yocto 原生环境变量配置脚本 |
| **配置文件生成** | 自动生成/覆写 `local.conf` 与 `bblayers.conf` | 不生成新配置，直接复用现有配置文件 |
| **`MACHINE` 设定** | 自动在配置中锁定目标板卡为 `ceb-gnrd` | 依赖已有配置或需手动声明 `export MACHINE=...` |
| **主要使用时机** | **首次初始化** / 全新构建时使用 | **日常开发** / 新窗口恢复环境时使用 |

---

### 3. 构建 OpenBMC 镜像与关键目标

* **构建完整 BMC SPI Flash 固件镜像**：
  ```bash
  bitbake obmc-phosphor-image
  ```

* **单独编译 Linux 内核与设备树 (DTS)**：
  ```bash
  bitbake virtual/kernel
  ```

* **单独编译与验证板级配置包**：
  ```bash
  bitbake entity-manager dbus-sensors ceb-gnrd-hardware-contract
  ```

### 4. 构建产物说明

构建产物存放于：`build/ceb-gnrd/tmp/deploy/images/ceb-gnrd/`
* `obmc-phosphor-image-ceb-gnrd-*.static.mtd`：BMC SPI 原始固件镜像（供编程器烧录或 QEMU 启动）。
* `obmc-phosphor-image-ceb-gnrd-*.tar.gz`：BMC 根文件系统压缩包。
* `fitImage`：包含 Linux 内核与 Initramfs 的镜像。
* `aspeed-ceb-gnrd.dtb`：编译后的板级设备树二进制。

---

## 四、在 QEMU 虚拟机中启动与测试

### 1. 启动 QEMU 虚拟机

CEB-GNRD 设备树禁用了 MAC0 和 MAC3，管理口 `eth0` 使用 **MAC2（设备树标签 `&mac1`，对应 QEMU 的第 2 个网卡）**，`eth1`（NC-SI）使用 MAC3（`&mac2`）。所以 QEMU 需要建两个网卡：第 1 个只是占位，第 2 个才是 `eth0`，并让 QEMU 的用户网络与 `eth0` 的静态地址 `192.168.185.200/24` 同一网段，端口转发才能找到它：

```bash
cd ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd
qemu-system-arm -M ast2600-evb -m 1G -nographic -monitor none \
  -drive file=obmc-phosphor-image-ceb-gnrd.static.mtd,format=raw,if=mtd \
  -nic user \
  -nic user,net=192.168.185.0/24,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623
```

* 串口控制台就是调试口 UART5（`ttyS4`），日志直接显示在当前终端；退出 QEMU：先按 `Ctrl-A`，再按 `X`。
* 想后台运行可放进 `tmux`：`Ctrl-B` 再按 `D` 暂离，`tmux attach` 回来。
* 把命令保存成脚本更方便：`~/run-bmc.sh`。

> ⚠️ **待验证**：上面的网卡对应关系按 QEMU 的网卡分配规则推断，网页打不开时先在 BMC 控制台里看 `ip addr show eth0` 是否有 `192.168.185.200`。如果你之前用的是旧版三网卡写法（`-net nic -net nic -net nic,netdev=net0`），那条命令对应的是旧的 MAC 映射，请改用本节的写法。
### 2. 访问 OpenBMC 服务

* **Web 管理界面 (HTTPS)**：
  浏览器打开：`https://127.0.0.1:8443/#/`
  > **浏览器证书警告绕过**：Chrome/Edge 提示“您的连接不是私密连接”时，在键盘上直接盲打输入 `thisisunsafe` 即可进入登录页面。

* **登录账号**：用户名 `root`，密码 `0penBmc`（`allow-root-login` 已启用）。

* **SSH 登录**：
  ```bash
  ssh -p 2222 root@127.0.0.1
  ```

* **Redfish API 接口测试**：
  ```bash
  curl -k https://127.0.0.1:8443/redfish/v1/
  ```

### 3. 系统服务状态检查

在 BMC 终端中运行：
```bash
# 检查失败服务
systemctl --failed

# 检查 Web 后端与 Socket 监听
systemctl status bmcweb
systemctl status bmcweb.socket

# 检查实体管理服务与 IP 状态
systemctl status xyz.openbmc_project.EntityManager.service
ip addr
```

---

## 五、Devtool 常用操作与板级开发全流程

`devtool` 是 Yocto 推荐的源码级开发与补丁管理利器。使用 `devtool` 可以修改现有组件、向现有组件新增源代码文件、创建全新的独立软件包，并一键归档存入指定的板卡级图层。

### 💡 devtool 核心开发流速览

| 开发场景 | 核心工作流步骤 |
| :--- | :--- |
| **场景 A：修改或向现有组件新增代码** | `devtool modify <recipe>` ➔ 在 `workspace` 中修改/新增文件并 `git commit` ➔ `devtool build <recipe>` ➔ `devtool finish <recipe> ../meta-ctopai/meta-ceb-gnrd`（自动生成 Patch 并追加进板卡层） |
| **场景 B：创建全新的独立软件包/服务** | `devtool add <pkg> <src_path/url>` ➔ 自动生成配方并在 `workspace` 调试构建 ➔ `devtool finish <pkg> ../meta-ctopai/meta-ceb-gnrd`（自动将新配方归档至板卡层） |

---

### 1. 修改现有开源组件并生成板级 Patch

以修改 `webui-vue` 前端界面为例：

#### (1) 提取源码到工作区 (`devtool modify`)
```bash
cd ~/openbmc/build/ceb-gnrd
devtool modify webui-vue
```
*Yocto 会自动将 `webui-vue` 源码提取到 `build/ceb-gnrd/workspace/sources/webui-vue/` 并初始化为 Git 仓库。*

#### (2) 修改代码并提交
```bash
cd workspace/sources/webui-vue
# 进行代码修改 ...

# 检查修改状态并提交
git status
git diff
git add .
git commit -m "ceb-gnrd: Customize webui theme

Signed-off-by: Your Name <your.email@example.com>"
```

#### (3) 实时编译与验证
```bash
cd ~/openbmc/build/ceb-gnrd
devtool build webui-vue

# 或构建完整镜像并在 QEMU 中验证
devtool build-image obmc-phosphor-image
```

#### (4) 生成 Patch 并归档至板级目录 (`devtool finish`)
```bash
devtool finish webui-vue ../meta-ctopai/meta-ceb-gnrd
```
* **执行结果**：
  1. 自动在 `meta-ctopai/meta-ceb-gnrd/recipes-phosphor/webui/files/` 目录下生成标准的 `000x-ceb-gnrd-*.patch`。
  2. 自动在 `meta-ctopai/meta-ceb-gnrd/recipes-phosphor/webui/webui-vue_%.bbappend` 的 `SRC_URI` 中追加该补丁引用。
  3. 自动从 `workspace` 中清理开发状态（**无需再手动执行 reset**）。

---

### 2. 向现有组件中增加全新源代码文件 / 模块

当需要为现有项目（如 `bmcweb` 或 `dbus-sensors`）新增自定义 `.cpp`、`.hpp` 或网页组件时：

#### (1) 进入源码工作区新增文件
```bash
cd ~/openbmc/build/ceb-gnrd
devtool modify dbus-sensors
cd workspace/sources/dbus-sensors
```

#### (2) 创建新文件并注册构建系统
```bash
# 创建新的传感器实现文件
touch src/CebGnrdSpecialSensor.cpp
touch src/CebGnrdSpecialSensor.hpp

# 在 CMakeLists.txt 或 meson.build 中将新文件加入编译列表
```

#### (3) 将新文件纳入 Git 管理并提交
```bash
git add src/CebGnrdSpecialSensor.cpp src/CebGnrdSpecialSensor.hpp CMakeLists.txt
git commit -m "ceb-gnrd: Add special sensor monitoring module

Signed-off-by: Your Name <your.email@example.com>"
```

#### (4) 编译并输出至板卡层
```bash
cd ~/openbmc/build/ceb-gnrd
devtool build dbus-sensors
devtool finish dbus-sensors ../meta-ctopai/meta-ceb-gnrd
```
*devtool 会将包含新增代码文件的 Git Commit 完整转换为包含新建文件的 Git Patch，并自动保存到板卡级目录的 `files/` 中。*

---

### 3. 使用 `devtool add` 创建全新的独立软件包 / 配方

当需要为 `ceb-gnrd` 引入一个全新的板级私有工具、自研服务或第三方库时：

#### (1) 基于本地源码或远程仓库新建配方
* **方式 A：基于本地源码目录**：
  ```bash
  cd ~/openbmc/build/ceb-gnrd
  devtool add ceb-gnrd-tool /home/test/src/ceb-gnrd-tool
  ```

* **方式 B：基于远程 Git 仓库**：
  ```bash
  devtool add my-custom-app https://github.com/my-org/my-custom-app.git
  ```

*devtool 会自动检测源码结构（如 CMake、Meson、Autotools、Python、Makefile），并在 `workspace/recipes/` 自动生成对应的 `.bb` 配方文件。*

#### (2) 编译与调试配方
```bash
devtool build ceb-gnrd-tool
```
*如果需要微调配方逻辑（如追加依赖、修改安装路径），可直接编辑 `workspace/recipes/ceb-gnrd-tool/ceb-gnrd-tool.bb`。*

#### (3) 归档全新配方到板卡层
```bash
devtool finish ceb-gnrd-tool ../meta-ctopai/meta-ceb-gnrd
```
*执行后，该新配方会自动安装在 `meta-ctopai/meta-ceb-gnrd/recipes-ceb-gnrd/ceb-gnrd-tool/ceb-gnrd-tool.bb`。*

#### (4) 将新软件包打包加入板卡镜像
在 `meta-ctopai/meta-ceb-gnrd/recipes-phosphor/packagegroups/packagegroup-ceb-gnrd-apps.bb` 中加入：
```bitbake
RDEPENDS:${PN}-system += " \
    ceb-gnrd-tool \
    "
```
或在 `meta-ctopai/meta-ceb-gnrd/recipes-phosphor/images/obmc-phosphor-image.bbappend` 中追加：
```bitbake
IMAGE_INSTALL:append = " ceb-gnrd-tool"
```

---

### 4. `devtool update-recipe` 与 `devtool finish` 的核心区别与配合

| 对比维度 | `devtool update-recipe` | `devtool finish` |
| :--- | :--- | :--- |
| **一句话定位** | **阶段性更新**（保留开发状态） | **最终交付并退出**（完成开发） |
| **生成 Patch / 更新配方** | ✅ 会将 Git 提交生成 Patch 并更新至指定图层 | ✅ 会将 Git 提交生成 Patch 并更新至指定图层 |
| **工作区状态 (`workspace`)** | 🟢 **继续保留**，处于开发模式 | 🔴 **自动清理并删除** `workspace` 中的源码和临时配方 |
| **后续 `bitbake` 编译来源** | 依然优先使用 `workspace/sources/` 下的代码 | 回归标准流程（从上游下载解压 + 板卡层 Patch 打补丁） |
| **适用场景** | 边开发边同步 Patch、需要继续调试修改 | 功能完全开发、测试通过，准备提交代码归档 |

> **⚠️ 常见疑问：`devtool finish` 执行完后还需要执行 `devtool reset` 吗？**
>
> **答案：完全不需要！**
> 因为 `devtool finish` 的底层逻辑已经自动包含了 `reset` 清理机制。执行成功后，`build/ceb-gnrd/workspace/sources/<recipe>` 目录和临时配置已被自动清除，该组件已彻底退出开发模式。如果此时再执行 `devtool reset`，系统会报错提示该配方不在工作区中。
> 
> *只有在**主动放弃当前修改、中途丢弃所有未保存改动**时，才需要手动执行 `devtool reset <recipe>`（若有未提交的改动可加 `-f` 强制放弃：`devtool reset -f <recipe>`）。*

#### 💡 推荐协同工作流：

```bash
# 1. 提取源码进入开发模式
devtool modify bmcweb

# 2. 修改代码并提交
cd workspace/sources/bmcweb
git commit -am "ceb-gnrd: Add custom redfish OEM handler"

# 3. 编译验证
devtool build bmcweb

# 4. [阶段性保存] 临时同步 Patch 到板卡层，不退出开发（必须加 -a 指定板卡层）
devtool update-recipe -a ../meta-ctopai/meta-ceb-gnrd bmcweb

# 5. [最终交付] 全部功能测试通过后，归档 Patch 并彻底清理工作区（会自动清理 workspace）
devtool finish bmcweb ../meta-ctopai/meta-ceb-gnrd
```

---

### 5. devtool 其他实用命令速查

| 操作需求 | 执行命令 |
| :--- | :--- |
| **仅更新补丁不退出工作区** | `devtool update-recipe -a ../meta-ctopai/meta-ceb-gnrd <recipe>` |
| **构建包含工作区代码的完整镜像** | `devtool build-image obmc-phosphor-image` |
| **放弃修改/重置工作区** | `devtool reset <recipe>`（强制放弃加 `-f`） |
| **查看当前处于工作区的配方列表** | `devtool status` |

---

## 六、当前功能与实现状态

> 下表只描述代码里已经实现的内容；标 ⚠️ 的项还没有上板验证或存在疑问，详见 `port_guide.xlsx` 底部红字的“待澄清”区块。

### 1. 板级硬件与固件布局

| 项目 | 现状 |
| :--- | :--- |
| BMC Flash | W25Q512JV 64 MiB；布局：U-Boot / 环境变量 / 内核 9 MiB / **ROFS 40 MiB** / **RWFS 14 MiB**（`FLASH_RWFS_OFFSET:flash-65536 = "51200"`，设备树分区与之对应） |
| 管理网口 `eth0` | MAC2 + RTL8211FS（`rgmii`，PHY 地址 2 ⚠️，复位由 CPLD 控制），静态 `192.168.185.200/24`，网关 `192.168.185.1`，DNS `192.168.185.1 / 223.5.5.5 / 223.6.6.6` |
| NC-SI 网口 `eth1` | MAC3，默认 DHCP；仅在主机上电后由 `ceb-gnrd-ncsi` 拉起 |
| MAC 地址 | 保存在 U-Boot 环境变量 `ethaddr` / `eth1addr`，固件升级不会擦除 `u-boot-env` 分区 |
| ADC | 内部 2.5 V 参考电压；`D3V0_BAT0` 因 R542/Q39 未焊会饱和 ⚠️ |
| eSPI | 仅 Peripheral 通道；驱动带复位恢复、错误计数和 debugfs 日志 ⚠️（见下） |
| PSU | `ceb-gnrd-psu-detect` 每 5 秒探测 0x58/0x59/0x5A，仅为在位模块创建 pmbus 设备；传感器有输入/输出电压、输入/输出功率和 PSUn_Temp（取 pmbus 的 temp2）⚠️ |

### 2. GPIO 行为

| GPIO | 行为 |
| :--- | :--- |
| UID 按键 `BMC_UID_BUTTON_N`（GPIOV0） | 低有效，按下切换 identify 灯组；UID 灯 `BMC_UID_LED`（GPIOV1）高有效 |
| CPU 开关机 `BMC_CPU_POWER_BUTTON`（V2）、复位 `BMC_CPU_RESET`（V3） | 低脉冲，由 `x86-power-control` 输出（200 ms / 强制关机 15 s / 复位 500 ms） |
| `BMC_CPU_PWRGD`（V4） | 高有效输入，供状态机判断上电 |
| 电源按键输入 `BMC_POWER_BUTTON_INPUT`（GPIOM2） | **只检测**：按下时写 SEL 和日志，不触发开关机，也不直通到 CPU 电源按键输出 |
| 告警灯 `BMC_SYS_ALERT_LED`（GPIOI5） | 电压越限、温度超过 Upper Critical（含更高的不可恢复上限）点亮，两者恢复后熄灭；watchdog 超时、BIOS 启动超时（**600 秒**）锁存点亮，BMC 重启后清除 |
| `BMC_FAN_BMC_OVERRIDE_N`（GPIOI6） | 风扇控制就绪后拉高，BMC 接管风扇；服务停止时拉低交还 CPLD |
| `BMC_HBLED_N`（GPIOP7） | eSPI 驱动就绪后启用内核 heartbeat 触发器 |
| `BMC_BIOS_FLASH_SELECT`（GPIOM1） | BIOS 升级时拉高切给 BMC，等 5 秒后烧写，结束后拉低 |
| `BMC_BIOS_BOOT_OK`（GPIOM7） | 只用于取消 BIOS 启动超时告警，不更新主机启动状态 |

### 3. Web 界面

* **已保留**：概要、事件日志、POST Code、转储、清单与 LED（系统/BMC/机箱三张表）、传感器、恢复出厂设置（仅 BMC）、KVM（含全屏）、固件、重启 BMC、SOL（只读）、服务器电源操作、虚拟媒体、日期与时间、风扇控制、网络、电源恢复策略、会话、用户管理、策略、证书。
* **已移除**（无后台支持）：SNMP Alerts、清除密钥、LDAP、资源管理/电源、“仅重置服务器选项”、清单页的 DIMM/风扇/电源/处理器/组件表。
* **虚拟媒体**：网页只提供“从浏览器读取镜像文件”（走 bmcweb 的 /vm/0/0 WebSocket → jsnbd → nbd → USB mass storage → 主机 VL805 USB 口）；“从外部服务器读取镜像文件”（CIFS/HTTPS）需要已停止维护的 virtual-media 服务，镜像里没有，网页默认也不显示。上板验证：网页选一个 ISO 点开始，主机里应出现一个 USB 光盘/U 盘；BMC 上 `ls /sys/kernel/config/usb_gadget/`、`ls /dev/nbd0`。
* **时间和 SEL**：BMC 系统时间默认从板上 RTC（NCT3015Y）读取，SEL 时间戳用系统时间。AST2600 内部 RTC 已关闭，NCT3015Y 是 `rtc0`。
* **SEL 记录**：电压、温度（含 CPU_MAX_TEMP / DIMM_MAX_TEMP，含不可恢复级别）、watchdog 超时、BIOS 启动失败（600 秒）、电源按键都会写 SEL。SEL 为 rollover：约保留最新 2000 条，满了自动丢弃最老的。
* **SSH / SCP**：BMC 用 dropbear 提供 SSH（22 端口），已带 `openssh-sftp-server` 和 `openssh-scp`，`scp` 新旧协议都可用，例如 `scp -P 2222 file root@127.0.0.1:/tmp/`（QEMU）。
* **SOL**：硬件上只能接收（CPU 串口输出接 BMC UART3 的 RX，TXD3 不接管脚），网页、SSH、IPMI 的 SOL 都不能向主机输入；网页提示为只读模式，终端禁用输入。
* **风扇控制**：6 个风扇可单独或统一设置；可选“BMC 重启后保留这些设置”（保存到 `/var/lib/ceb-gnrd`，重启和断电重启后恢复），不勾选则 BMC 重启后回到自适应。该功能依赖 bmcweb 的 `dbus-rest`。
* **升级后保留**：普通固件升级不会清读写分区；需要清读写分区的升级会按白名单保存时区、主机名、SSH 主机密钥、网站证书和风扇设置。恢复出厂则全部清除（MAC 不受影响）。

### 4. IPMI

* `mc info`：Device ID 32，Device Revision 2，Product ID 3346（`0x0D12`），Manufacturer ID 6659（`0x1A03`），在 BMC 上的 ipmitool 显示 `CTOPAI` / `CEB-GNR-D`。
* 传感器：已启用 `dynamic-sensors`，电压/温度/风扇/CPU_MAX_TEMP/DIMM_MAX_TEMP 都会出现在 IPMI。CPU_MAX_TEMP 告警阈值 90/98/105 ℃，DIMM_MAX_TEMP 80/85/95 ℃（UNC/UC/UNR，只设上限）；6 个风扇不设告警，没接风扇读 0 RPM 属正常；温度读不到时全速（temp-max 发布 127 ℃），风扇读到几个都不影响（FailSafePercent=30）。
* 白名单：`Master Write-Read` 仅限 PCIe 槽位总线 i2c-0 至 i2c-5（本板没有 slot 2 的总线）。

---

## 七、验证清单

### 1. 构建后先在 QEMU 里检查

```bash
systemctl --failed --no-pager                 # QEMU 缺少 KCS、eSPI、PECI 等硬件，对应服务失败属预期
journalctl -b -p err --no-pager | tail -40
ip addr show eth0                              # 应有 192.168.185.200
cat /etc/os-release | head                     # VERSION_ID 应为 1.0.0
ipmitool mc info                               # Manufacturer Name CTOPAI，Product Name CEB-GNR-D
```

网页逐项点开：菜单里不应再有 SNMP / 清除密钥 / LDAP / 资源管理；风扇页应列出 6 个风扇；SOL 页应有只读提示；KVM 页应有“全屏”按钮。

### 2. 上板后重点验证（对应端口指南红字项）

| 项目 | 命令 / 方法 |
| :--- | :--- |
| eSPI | `dmesg \| grep -i espi`；`cat /sys/kernel/debug/*espi*/regs`；对照分析仪抓包 |
| PHY | U-Boot：`mdio list`；Linux：`dmesg \| grep -i -E "phy\|mdio"`、`ethtool -S eth0`、`iperf3` |
| PSU | 插 1 个和 2 个模块各验证：`journalctl -u ceb-gnrd-psu-detect`；`ipmitool sdr` 里应有 PSUn_Temp，`ls /sys/class/hwmon/*/temp*_input` 核对 temp2 确实是电源温度 |
| 电源按键 | `journalctl -u ceb-gnrd-power-button-log -f`；`ipmitool sel list \| tail -3` |
| 告警灯 | 电压越限、温度超 Upper Critical、watchdog 超时、BIOS 启动超过 600 秒各验证一次（四种共用一个灯，前两种恢复后灭，后两种重启 BMC 才灭） |
| 风扇 | `busctl tree xyz.openbmc_project.EntityManager \| grep -i pid`；`ls /xyz/openbmc_project/control/fanpwm/`；网页保存后查看 `journalctl -u ceb-gnrd-fan-settings` |
| BMC 状态 | `obmcutil state`（`Device Available` 取决于 BMC 是否为 Ready） |

---

## 八、构建加速与常见问题

### 1. 缩短编译时间

* 不要随意 `cleansstate`，bitbake 会按内容判断哪些包要重编。
* 只改了一个包就单独构建，补丁问题可以只跑 `bitbake -c patch <包>`（几秒）。
* 把下载目录和共享缓存放在构建目录之外，删掉 `build/` 重来也不必重新下载、重新编译，在 `build/ceb-gnrd/conf/local.conf` 末尾加：

```bash
DL_DIR = "/home/test/yocto-cache/downloads"
SSTATE_DIR = "/home/test/yocto-cache/sstate"
```

### 2. 本项目遇到过的典型错误

| 现象 | 原因与处理 |
| :--- | :--- |
| `patch-fuzz` QA 错误 | 补丁上下文与源码不完全一致；`webui-vue` 补丁必须前后各 3 行完整上下文，用工具按实际文件生成，不要手写 hunk 头 |
| `malformed patch at line N` | hunk 头里的行数写错 |
| `Missing Upstream-Status` | 补丁说明里要有 `Upstream-Status:` 行 |
| `do_patch` 里的 shell 追加报 `SyntaxError` | `do_patch` 是 Python 任务，shell 逻辑要写成独立任务并用 `addtask` |
| 镜像大小超限 | `FLASH_RWFS_OFFSET` 必须写成带 override 的 `FLASH_RWFS_OFFSET:flash-65536`，普通赋值会被盖掉 |
| 打包阶段文件冲突 | 两个包安装了同一个文件（如 `ipmitool` 自带的 IANA 企业编号表），改为在原包安装后追加 |
| U-Boot 找不到 `.dtb` | 2019.04 需要把 `ast2600-ceb-gnrd.dtb` 登记进 `arch/arm/dts/Makefile`（bbappend 里已处理） |
| 网页编译 `Unexpected token` | 模板字符串反引号丢失，补丁里的 JS 要逐字核对 |

### 3. 修改网页补丁的建议流程

1. 从 GitHub 下载对应版本的网页源码文件，生成改动后的文件。
2. 用工具生成带 3 行上下文的标准补丁（不要手写 hunk 头）。
3. 在构建机上先 `bitbake -c patch webui-vue`，通过后再完整构建。
