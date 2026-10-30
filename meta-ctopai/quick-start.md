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
| **配置文件生成** | 首次生成配置；已有配置复用并执行板级迁移 | 不生成新配置，直接复用现有配置文件 |
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

产物目录：`build/ceb-gnrd/tmp/deploy/images/ceb-gnrd/`。各文件用途不同：

| 产物 | 用途 |
|---|---|
| `obmc-phosphor-image-ceb-gnrd.static.mtd`（链接到带构建时间的文件） | 编程器/QEMU 使用的完整原始镜像，64 MiB，即 67,108,864 字节；编程器从地址 0 写入 |
| `*.static.mtd.tar` | Web/Redfish 使用的 BMC 分区升级包，不能直接作为编程器原始镜像 |
| `image-bmc` / `flash-ceb-gnrd` | 完整 `.static.mtd` 镜像的链接 |
| `image-kernel` / `fitImage` | 内核、设备树和 initramfs 的 FIT 镜像 |
| `image-rofs` | SquashFS-XZ 根文件系统，用于 `bootnet` / `netupdate` |
| `image-rwfs` | JFFS2 可写分区镜像 |

固件发行版本由 `meta-ctopai/conf/distro/ctopai-openbmc.conf` 的 `DISTRO_VERSION` 指定：当前为 `2.2.0`，Web 和 `/etc/os-release` 使用此字符串，IPMI `mc info` 显示 `2.02`。Git 标签 `2.00-golden-release` 标记的是此前的 2.00 发布提交，不会随工作区版本修改而移动。

编程器烧录后，整片读回 64 MiB 并与实际烧录的原始文件比较。若出现 `unable to read id index table` 或其他 SquashFS 挂载错误，先核对文件格式、完整性、烧录偏移和高地址区域；完整启动日志与读回文件可帮助区分镜像问题和 SPI 读取问题。

## 四、在 QEMU 虚拟机中启动与测试

### 0. 推荐方式：用 `run-qemu.sh` 启动带硬件模型的模拟器

`bitbake obmc-phosphor-image` 完成后，在构建机上直接运行（仓库根目录有一个指向 `meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh` 的符号链接）：

```bash
cd ~/openbmc
./run-qemu.sh
```

脚本使用镜像 `qemuboot.conf` 指向的 BitBake native QEMU（已带本板的模型补丁，见 `tools/qemu/patches/`），并按真实地址挂上：BMC Flash 与 64 MiB BIOS Flash、`eth0`（MAC2）与 `eth1`（NC-SI）、4 个温度传感器（`i2c-6` 的 0x48–0x4b）、PSU 槽位（`i2c-7` 的 0x58–0x5a）、FRU EEPROM（`i2c-10`，1 KiB）、RTC（NCT3015Y，`i2c-9` 的 0x6f）、风扇转速、ADC、PECI CPU，以及一个模拟主机（上电/复位时序、POST 码、COM1 串口、KCS、VGA、USB）。随后在 `http://127.0.0.1:8800` 打开浏览器控制面板，可以按电源/UID 按钮、注入温度/电压/PSU/风扇故障、切换网络状态等。

| 服务 | 地址 |
| :--- | :--- |
| BMC Web / Redfish | `https://127.0.0.1:8443` |
| BMC SSH | `ssh -p 2222 root@127.0.0.1` |
| IPMI LAN（UDP） | `127.0.0.1:2623` |
| 硬件模拟控制台 | `http://127.0.0.1:8800` |

常用环境变量：`DEPLOY`（镜像目录）、`STATE`（状态目录，默认 `~/qemu-ceb-gnrd`，存放 FRU 文件、日志、QMP socket）、`BIOS_FLASH`、`PANEL_PORT`、`NO_PANEL=1`、`NETWORK_CAPTURE=1`、`PECI_CPU=gnrd|spr`。模拟器的详细说明、接口范围和已知限制见 `tools/qemu/README.md`。下面的小节是不带硬件模型的“裸 QEMU”写法，只用于验证 Web/SSH/Redfish 等用户空间功能。

### 1. 备用方式：直接用 `qemu-system-arm` 启动

CEB-GNRD 设备树禁用了 MAC0 和 MAC3，管理口 `eth0` 使用 **MAC2（设备树标签 `&mac1`，对应 QEMU 的第 2 个网卡）**，`eth1`（NC-SI）使用 MAC3（`&mac2`）。所以 QEMU 需要建两个网卡：第 1 个只是占位，第 2 个才是 `eth0`，并让 QEMU 的用户网络网段为 `192.168.185.0/24`、DHCP 地址池从 `192.168.185.200` 开始（`dhcpstart=`）：`eth0` 默认用 DHCP 取地址，第一个租约正好是 `192.168.185.200`，端口转发才能找到它：

```bash
cd ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd
qemu-system-arm -M ast2600-evb -m 1G -nographic -monitor none \
  -drive file=obmc-phosphor-image-ceb-gnrd.static.mtd,format=raw,if=mtd \
  -nic user \
  -nic user,net=192.168.185.0/24,host=192.168.185.1,dhcpstart=192.168.185.200,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623
```

* 串口控制台就是调试口 UART5（`ttyS4`），日志直接显示在当前终端；退出 QEMU：先按 `Ctrl-A`，再按 `X`。
* `ttyS4` 的登录提示等待 `multi-user.target` 和 `obmc-led-group-start@bmc_booted.service` 启动任务结束后显示。服务任务失败也不会禁止登录；不等待所有服务健康。启动任务卡住可能延迟登录，登录后后台日志仍可能输出。该实例移除了 `Before=getty.target` 并关闭隐式目标排序，显式保留系统初始化和关机依赖，避免启动顺序循环。
* 想后台运行可放进 `tmux`：`Ctrl-B` 再按 `D` 暂离，`tmux attach` 回来。
* 把命令保存成脚本更方便：`~/run-bmc.sh`。

> **QEMU 里 ping 的限制**：QEMU 的 `user` 网络（slirp）是虚拟的 NAT 网络。① 它默认不转发 ICMP，ping 外网大多不通，但 TCP/UDP（`curl`、`nslookup`）是通的，验证外网请用 `curl` 而不是 `ping`；② 192.168.185.0/24 整个网段都在 QEMU 内部，宿主机的真实地址（如 192.168.185.84）在里面是不存在的，虚拟机访问宿主机用 `host=` 指定的 192.168.185.1，DNS 是 192.168.185.3。

> **U-Boot 启动方式与 TFTP**：U-Boot 固定从本地 SPI 闪存启动，TFTP 只用于手动网络启动调试和 `run netupdate` 更新闪存；QEMU 里的服务器地址和物理板子不同（192.168.185.1，需要 `tftp=` 参数），详见本章 “4. U-Boot 的 TFTP 使用”。

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

* **Redfish API 接口测试**（在宿主机 Ubuntu 终端里执行；BMC 镜像里也带了 `curl`，在 BMC 里用 `https://127.0.0.1/` 不带端口）：
  ```bash
  curl -k https://127.0.0.1:8443/redfish/v1/
  # 以下需要登录；-u 用户名:密码，-k 忽略自签名证书
  curl -k -u root:0penBmc https://127.0.0.1:8443/redfish/v1/Systems/system
  curl -k -u root:0penBmc https://127.0.0.1:8443/redfish/v1/Chassis/chassis/Sensors          # 传感器列表
  curl -k -u root:0penBmc https://127.0.0.1:8443/redfish/v1/Systems/system/LogServices/EventLog/Entries   # 事件日志（SEL）
  curl -k -u root:0penBmc https://127.0.0.1:8443/redfish/v1/Managers/bmc/LogServices/Dump/Entries         # 转储列表
  ```
  创建一个 BMC 转储（返回一个任务，QEMU 里约 30 秒完成，期间再提交会返回 503 `ResourceInUse`）：
  ```bash
  curl -k -i -u root:0penBmc -X POST -H "Content-Type: application/json" \
    -d '{"DiagnosticDataType":"Manager"}' \
    https://127.0.0.1:8443/redfish/v1/Managers/bmc/LogServices/Dump/Actions/LogService.CollectDiagnosticData
  curl -k -u root:0penBmc https://127.0.0.1:8443/redfish/v1/TaskService/Tasks/0     # 看任务状态
  ```
  `-i` 会把 HTTP 状态码和响应头也打印出来，排查接口错误时很有用。

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

### 4. U-Boot 的 TFTP 使用（虚拟机与物理主板的区别）

**启动方式**：U-Boot 的默认 `bootcmd` 固定为 `run bootspi`，只从本地 SPI 闪存加载内核，不会自动走网络。TFTP 只在你手动操作时使用：手动网络启动（调试内核用）和 `run netupdate`（更新闪存，见 4.5）。

| 项目 | 物理主板 | QEMU 虚拟机 |
|---|---|---|
| TFTP 服务器地址 | **192.168.185.84**（Ubuntu 主机，U-Boot 默认 `serverip`） | **192.168.185.1**（QEMU 虚拟网络里的“宿主机”，`host=` 指定） |
| TFTP 服务由谁提供 | Ubuntu 上的 `tftpd-hpa`（目录 `/srv/tftp`） | QEMU 自带，启动命令里加 `tftp=/srv/tftp` |
| 网络 | 必须和 Ubuntu 在同一局域网（经交换机），192.168.185.0/24 | QEMU 的 `-nic user` 虚拟网络，只在虚拟机内部有效 |
| 手动 TFTP 前要做什么 | 确认生产 MAC、空闲 ipaddr 与实际 serverip | 手动 `setenv serverip 192.168.185.1` |
| `mii`、PHY 寄存器、RGMII 时序 | 真实硬件，**必须上板验证** | 模拟的（所有 PHY 地址都应答，页寄存器读出全 0），不能代表真实板子 |

**镜像**：`fitImage` 只含内核、设备树和 initramfs，手动网络启动只替换这一部分，根文件系统仍用本地闪存的 rofs。若要同时从 TFTP 使用新 rootfs，部署 `image-kernel` 和 `image-rofs` 后执行 `run bootnet`（RAM overlay，不写 Flash）。文件在 `build/ceb-gnrd/tmp/deploy/images/ceb-gnrd/fitImage`，文件名必须保持 `fitImage`。

#### 4.1 在 Ubuntu 上准备 TFTP 服务（物理主板和 QEMU 都用同一个目录）

```bash
sudo apt install -y tftpd-hpa
sudo tee /etc/default/tftpd-hpa >/dev/null <<'EOF'
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --create"
EOF
sudo mkdir -p /srv/tftp
sudo cp ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd/fitImage /srv/tftp/fitImage
sudo chmod 644 /srv/tftp/fitImage
sudo chown -R tftp:tftp /srv/tftp
sudo systemctl restart tftpd-hpa
# 自测：能下载下来且大小和源文件一致
cd /tmp && tftp 127.0.0.1 -c get fitImage && ls -l fitImage
```

每次重新编译后，要重新复制 `fitImage`。

#### 4.2 QEMU 虚拟机里手动网络启动

QEMU 启动命令里给第二个网卡加 `tftp=/srv/tftp`：

```bash
cd ~/openbmc/build/ceb-gnrd/tmp/deploy/images/ceb-gnrd
qemu-system-arm -M ast2600-evb -m 1G -nographic -monitor none \
  -drive file=obmc-phosphor-image-ceb-gnrd.static.mtd,format=raw,if=mtd \
  -nic user \
  -nic user,net=192.168.185.0/24,host=192.168.185.1,dhcpstart=192.168.185.200,tftp=/srv/tftp,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623
```

看到 `Hit any key to stop autoboot` 时按任意键，在 `ast#` 提示符下：

```
setenv serverip 192.168.185.1
tftpboot 0x83000000 fitImage
bootm 0x83000000
```

成功的标志：`TFTP from server 192.168.185.1`，一排 `#`，`Bytes transferred = 5656980`（字节数应与 `fitImage` 大小一致），然后 `## Loading kernel from FIT Image at 83000000` 并进入 Linux。`/srv/tftp/fitImage` 要对运行 QEMU 的用户可读。

> 在 QEMU 里不改 `serverip`（还是 192.168.185.84）直接 `tftpboot`，会停在 `Loading: *`，最后 `ARP Retry count exceeded`，因为 .84 在虚拟网络里不存在。

#### 4.3 物理主板上手动网络启动

1. Ubuntu 的网口配好 `192.168.185.84/24`，BMC 的网口和它在同一局域网（经交换机或直连）。
2. 更新后的 U-Boot 不再提供固定 `ethaddr` / `eth1addr`，也不会在缺失时自动补齐。先读取 `printenv bootcmd ethaddr eth1addr ipaddr serverip`，保留生产 MAC；仅在需要恢复默认环境时执行 `env default -a`，然后重新写入本板唯一的两路 MAC 和实际网络参数，再 `saveenv`。例如：

```
setenv bootcmd 'run bootspi'
setenv ethaddr <本板eth0的生产MAC>
setenv eth1addr <本板eth1的生产MAC>
setenv ipaddr <BMC在此网络中的空闲IPv4地址>
setenv serverip <TFTP服务器IPv4地址>
saveenv
```

   尖括号内容必须替换为实际值，不能原样执行。已有保存的 MAC 不会被删除；整片编程器烧录或主动更新环境分区会改变环境内容。
3. 重启后应直接从本地闪存启动，不出现 TFTP。要手动网络启动时，在 `Hit any key to stop autoboot` 时按任意键，然后执行 `tftpboot 0x83000000 fitImage` 和 `bootm 0x83000000`，串口日志里应出现 `TFTP from server 192.168.185.84; our IP address is 192.168.185.200` 和 `Bytes transferred`。
4. 出问题时的排查（**只适用于物理板子**）：
   * Ubuntu：`ip -br addr`（地址在接 BMC 的网卡上）、`sudo ufw status`（放开 UDP 69）、`sudo journalctl -u tftpd-hpa -f`（看有没有收到请求）。
   * 抓包（局域网流量大，用 BMC 的 MAC 过滤）：`sudo tcpdump -i <网卡> -n -e ether host 02:00:00:00:00:01`。
   * 链路已 `up` 但 ARP/TFTP 不通：先检查 IP、服务器、网线和交换机，查看 `mdio list` / `ethtool eth0`。当前代码使用 PHY 地址 1 和 `rgmii-id`，不要照旧说明向地址 2 写延时寄存器。

#### 4.4 U-Boot 里的 NC-SI 口

NC-SI 口（`&mac2`）在 U-Boot 里**不启动**（设备树里禁用）：U-Boot 只用 eth0 取镜像。不要给它加 `phy-mode` 再启用，那样 NC-SI 探测会让 U-Boot 崩溃（`data abort`，不断复位）；不加则只会打印 `Invalid PHY interface '<NULL>'`。Linux 里 NC-SI 口 `eth1` 自动使能并用 DHCP 取地址：主机上电后由 `ceb-gnrd-ncsi` 服务把 `eth1` 拉起（E810 没有待机供电，主机关机时 NC-SI 不可用，拉起后内核 NC-SI 栈自动选择通道；E810 上电后不一定立刻就绪，服务会在 30 秒内没有链路时对 `eth1` 做 down/up 重试，每 30 秒一次，最多 3 次，日志见 `journalctl -t ceb-gnrd-ncsi`），`systemd-networkd` 按 `DHCP=ipv4` 获取地址。
#### 4.5 在 U-Boot 里通过 TFTP 更新闪存（`run netupdate`）

U-Boot 默认环境里带了变量 `netupdate`，把“TFTP 取内核和根文件系统，再写进 SPI 闪存”合成一条命令：

```
run netupdate
reset
```

它做的事（任何一步失败都会停止并打印 `Network update FAILED`）：

1. `sf probe 0`，选中 BMC 的 SPI 闪存。
2. 从 `serverip` 取 `image-kernel`（变量 `netupdate_kernel`）到内存 `0x90000000`，检查大小不超过 9 MiB，`sf update` 写到 `0x100000`。
3. 取 `image-rofs`（变量 `netupdate_rofs`），检查大小不超过 40 MiB，`sf update` 写到 `0xa00000`。
4. 成功后提示 `Network update done, run reset`。

**不会改动**：U-Boot 本体和环境（`0x000000` 到 `0x0fffff`，所以保存的 `ethaddr`、`bootcmd` 不丢）、可写分区 `rwfs`（`0x3200000`，所以用户配置不丢）。

**准备**：把 `image-kernel`、`image-rofs` 放进 TFTP 目录（`sudo cp -L <deploy 目录>/image-kernel /srv/tftp/` 和 `image-rofs`，`chmod 644`）。物理主板上 `serverip` 默认就是 192.168.185.84；QEMU 里先 `setenv serverip 192.168.185.1`（并且 QEMU 要带 `tftp=`）。文件名不同时，用 `setenv netupdate_kernel <名字>` / `setenv netupdate_rofs <名字>` 修改。

**注意**：
* 写入过程中断电可能让镜像损坏；这条命令不写 U-Boot，所以即使失败，也还能进入 U-Boot 重新执行。
* 旧的已保存环境会盖住新默认值，需要恢复默认环境时，先记录并恢复生产 MAC/网络配置再 `saveenv`（见 4.3）。
* 在 QEMU 里它会改写 `.mtd` 文件，先备份：`cp obmc-phosphor-image-ceb-gnrd.static.mtd backup.mtd`。
* `0x90000000` 是内存里的空闲区，1008 MiB 内存足够；分区偏移和大小来自设备树，改了分区布局要同步修改 `ceb-gnrd-env.h`。
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

本章依据当前板级代码说明功能。`port_guide.xlsx` 是硬件配置和用途表，不再包含旧版红字“待澄清”区块。配置、接口存在和实际硬件数据通路正常应分别确认。

### 1. 板级硬件与固件布局

| 项目 | 当前配置 |
|---|---|
| BMC Flash | W25Q512JVFIQ，64 MiB；U-Boot 896 KiB、环境 128 KiB、kernel 9 MiB、ROFS 40 MiB、RWFS 14 MiB；ROFS 起点 `0x00a00000`，RWFS 起点 `0x03200000` |
| 管理网口 eth0 | 物理 MAC2（DT mac1），RTL8211FS，PHY 地址 1，`rgmii-id`；默认 IPv4 DHCP |
| NC-SI eth1 | 物理 MAC3（DT mac2），Intel E810；Host On 且 BIOS POST complete 后等待 5 秒，再初始化；关机/POST 撤销时关闭，尊重 NICEnabled 设置 |
| 网络匹配 | eth0 使用 `Path=platform-1e680000.ethernet`；eth1 使用 `Path=platform-1e670000.ethernet`；配置迁移保留 IP/DHCP/DNS/静态邻居 |
| MAC 地址 | U-Boot 不再编入或自动补齐固定 MAC；已有保存的 `ethaddr` / `eth1addr` 继续使用，生产板应配置唯一地址 |
| PSU | BMC 启动时一次探测 Linux i2c-7 的 0x58/0x59/0x5a；MEG-CRPS800AOP 使用 megcrps800，其余型号或未知型号默认 generic pmbus；不周期轮询/自动热插拔换驱动 |
| ADC / 温度 | 16 路 ADC、4 个 LM75A 兼容板级温度；CPU/DIMM 最高温来自 PECI。D3V0_BAT0 分压仍需结合实际焊接确认 |
| 调试串口 / SOL | UART5/ttyS4 是 115200 调试口；默认 Host SOL 为物理 UART3/ttyS2，Web 可另选 VUART1/ttyVUART0 |
| RTC | NCT3015Y-R（Linux i2c-9，0x6f）使用 nct3018y 驱动作为 rtc0；片内 RTC 关闭；系统/RTC 时间保持 UTC，页面可按浏览器时区显示 |
| eSPI / KCS | Peripheral 和 Virtual Wire ready；KCS3 在 0xCA2/0xCA3，未配置 KCS SerIRQ；POST 监听 0x80 |
| CPLD JTAG | 专用 Master-1，寄存器 `0x1e6e4000`；不是 GPIOI Master-2；板级驱动提供 `/dev/ceb-gnrd-jtag` |
| Watchdog | AST2600 WDT1，systemd RuntimeWatchdogSec=120s，SoC reset；内核 panic 后 5 秒重启 |
| SD / eMMC | 未接入，设备树禁用；BMC 使用 SPI NOR 启动 |

### 2. GPIO 与电源行为

| 信号 | 行为 |
|---|---|
| UID / GPIOV0 | 低有效；短按释放保留 chassis identify 功能；连续按住 5 秒请求正常 BMC 重启，长按释放不再切换 identify |
| 实体 Power button / GPIOM2 | 仅通知 BMC并记录日志/SEL；不由 BMC 转发实体按键动作；实体 Reset button 没有接入 BMC |
| BMC_CPU_POWER_BUTTON / GPIOV2 | x86-power-control 输出低有效脉冲：普通 200 ms，强制关机 8000 ms |
| BMC_CPU_RESET / GPIOV3 | x86-power-control 输出低有效 500 ms 复位脉冲 |
| BMC_CPU_PWRGD / GPIOV4 | 高有效，提供实际机箱 DC 电源状态 |
| BMC_BIOS_BOOT_OK / GPIOM7 | 高有效 POST complete；OperatingSystemState 为 Standby；下降沿参与热复位识别 |
| 风扇接管 / GPIOI6 | 高为 BMC PWM、低为 CPLD；取得控制后清 reset tolerance，停止时交还 CPLD。异常停止和实板复位电平仍需硬件验证 |
| BIOS Flash select / GPIOM1 | 仅在 BIOS 升级锁和稳定 Host Off 条件下切给 BMC；写入结束后解除 SPI-NOR 绑定再交还 CPU |
| 心跳 / GPIOP7 | 低有效；eSPI 驱动就绪后启用内核 heartbeat 触发器 |
| 系统告警 / GPIOI5 | 电压 Critical、温度 UNR及 CPU/DIMM Upper Critical、BIOS 启动超时、Host watchdog 共同驱动 enclosure_fault；解除规则见第九章 |

### 3. Web 与升级

* 固件页显示运行镜像；缺失 BIOS 版本显示 `N/A`。概览固件卡显示运行版本、Build ID 和 Git commit；Source version 已隐藏。信息来自系统现有版本数据，未额外生成编译日志文件。
* BMC 上传 `.static.mtd.tar`；BIOS 上传含完整 64 MiB BIOS 镜像的 `.tar` 包，不能直接上传裸 `.bin`/`.rom`。CPLD 上传 `.bit`。提示位于上传区上方，成功后的 AC power cycle 说明合并为一处。
* BMC 分区选择：kernel/rofs 默认选中并须一起更新；rwfs 按选择处理；U-Boot/环境默认不选，启用时需要确认。环境更新会清除保存的 MAC/网络启动配置。分区选择在后端再次校验，整片 `.static.mtd.all.tar` 更新被拒绝。
* BMC/BIOS 与 CPLD 升级期间，另一组上传/启动按钮禁用；后端使用共享升级锁、电源互锁与重启保护。网页禁用只是第一层，不能代替后端校验。
* 固定风扇档位为 20%、30%、40% … 100%，默认表单值 60%。可独立控制 SYS_FAN0–5或统一控制，自动模式为 30–100%。IPMI 固定占空比接受 10–100%，网页提供的是 10% 步进预设。
* 保存调用 `SetFan`；网页显示 IPMI 设置的自定义占空比，多风扇配置不一致时显示“混合”。变更前保存快照，写入和控制重载失败时回滚。保留选项将配置保存到 `/var/lib/ceb-gnrd/fan-settings.json`。
* 六个控制器配置或上下限不可读/非法时，GetFans 返回 D-Bus 错误，Web 显示加载失败，IPMI 返回响应错误，不再把未知模式显示为自动。
* 风扇页首次成功读取（含失败后的自动重试）会初始化全部表单字段；之后刷新同步未编辑的字段并保留用户未保存的修改。保存期间禁用输入，并忽略保存前发起的过期读取。
* 虚拟媒体的本地 ISO 会话可跨 BMC 内部菜单保持；浏览器刷新/关闭会断开。切换标签或后台休眠仍可能导致 WebSocket 断流，不能承诺挂载持续；独立挂载窗口方案尚未实现。
* KVM、SOL、时间、事件日志和传感器页面提供各自的实时刷新/显示逻辑。KVM 键释放失败导致重复输入的缺口尚未修复，需要保留为已知问题。
* Web 仅保留 BMC dump、单运行镜像、实际支持的清单/设置；PLDM、DCMI、SMBIOS 清单、远端 CIFS/HTTPS 虚拟媒体未配置。

### 4. IPMI、日志和保留策略

* `ipmitool mc info`：Device ID 32、Device Revision 2、Manufacturer ID 49871、Product ID 59380（0xE7F4）；当前发行版本对应 Firmware Revision 2.02。
* `ipmitool raw 0x30 0x01` 读取六个风扇，返回 25 字节。设置示例：`ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01`，全部固定 60%并保留；设置需要 Admin。
* CPU 温度上限 UNC/UC/UNR 为 90/98/105°C，DIMM 为 80/85/95°C。电压使用 LC/UC；风扇没有转速阈值告警。板级私有 UNR接口不会触发 HardShutdown。
* Host Off 时 CPU/DIMM 值为 0，停止 Host 供电传感器失读告警；Host On 失读时发布至少 70°C 的保护输入，保留更高的最后读值，直到恢复有效采样或确认 DC Off。告警使用真实读值，不用保护值制造温度告警。
* POST 只保留最近一次 Host 启动，每轮最多 512 条；冷启动/热复位切换历史。BMC或 POST服务重启恢复当前轮，不以空内存缓存作为新 Host 启动。按 4F/60、90、AD、AF 等锚点判断 AMI/Intel 参考上下文；原始码仍保留，未知/OEM码不强行判为错误。
* Web POST 解码优先采用项目于2026-10-19提供的BIOS源码定义：`7E=CHECKPOINT_MAJOR_PIPE_SYNC`（内存流水线同步）、`BC=CHECKPOINT_MAJOR_RAS_CONFIG`（内存RAS配置）、`BF=CHECKPOINT_MAJOR_MRC_START_STOP`（MRC开始/结束，不能固定判为完成）、`C6=CHECKPOINT_MAJOR_DIMM_INFO`（DIMM信息）、`CE=CHECKPOINT_MAJOR_MEM_LATE`（内存初始化后期）、`AF=DXE_EXIT_BOOT_SERVICES`（退出UEFI引导服务检查点）。来源路径为`Intel/CpRcPkg/Include/Memory/MemoryCheckpointCodes.h`及`Intel/ServerPlatformPkg/Library/PlatformPostCodeMapLib/PlatformPostCodeMapLib.c`；未提供对应BIOS/RC/BKC版本，其他Intel码仍为跨平台参考，早期AF及缺失阶段的序列仍显示提示，不据单码判定OS启动成功。
* GNR-D BWG（文档762471，Rev.0.9，2025-02，第36–39页）说明Port 80h路由、早期`0x80`及后续`0x80–0x83`解码，没有给出完整POST码表。当前BMC只监听I/O端口`0x80`；端口地址不等于POST码值，单字节采样不能还原完整的16位FSP码，亦不把BIOS Mailbox的`0x80`命令解释成POST码。
* Web POST 页面常显阅读说明；有明确序列上下文的记录可展开持续停码时的排查参考。外部故障排查文档仅补充检查建议，不覆盖项目 BIOS 定义，不凭单码判定故障部件、DIMM 槽位或启动成功。
* 本次完整 journal 在 RAM `/run/log/journal`，最多约 8 MiB；警告及以上文本保存在 `/var/log/bmc-system.log`，每文件 512 KiB、5个旧文件。SEL每文件 15 KiB、1个旧文件；Redfish日志每文件 64 KiB、1个旧文件，由 rsyslog 写入时轮转。定时器每分钟监控 RWFS 空间。
* 普通重启不主动清除持久日志；重写 RWFS 的升级按白名单恢复设置，SEL/Redfish/系统警告日志不在白名单中，不能承诺保留。恢复出厂清除 RWFS；U-Boot环境位于独立分区。
* SSH 使用 Dropbear，现代 SCP走 SFTP（保留 openssh-sftp-server）；旧 `scp -O` 和 rsync 不随本镜像提供。

* FRU 生成：`ipmitool fru gen [文件名]`（默认 `fru.bin`）。会依次提示 Chassis、Board、Product 三个区域的每个字段，每项都显示含义/格式，默认值已经填在输入行里，可以直接修改，直接回车则采用默认值。默认值：制造商 `CTOPAI`，Board/Product 名称 `CEB-GNR-D`，Chassis PN `93-XXXXX-XX`、Board PN `91-59380-A0`、Product PN `81-59380-A0`，Product 版本 `v1.0`，Product 资产标签 `Xeon6-SOC`，Board / Product FRU file ID `0`，Board 生产日期默认为本次生成开始时的 BMC UTC 时间（精确到分钟，可手动修改；超出 FRU 时间字段范围时仍显示当前时间，并提示校正 BMC 时间或修改生产日期），序列号为生成当天 UTC 日期 `YYMMDD` 加 `0001`，例如 `2610060001`（序号可手动修改，不自动递增）。输入不合法会提示重输，标准输入不是终端时全部用默认值；字段是可打印 ASCII，最长 63 个字符，日期格式 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:MM`（UTC，留空表示未指定），机箱类型填数字（默认 `0x17` 机架式）。生成后用 `ipmitool fru write 0 fru.bin` 写入主板 FRU（EEPROM 1 KiB，生成镜像须不超过 EEPROM 容量），再用 `ipmitool fru print 0` 核对。

## 七、验证清单

### 0. 一键检查脚本 `ceb-gnrd-check`

镜像里自带 `/usr/bin/ceb-gnrd-check`（源文件 `recipes-phosphor/utils/files/ceb-gnrd-check.sh`），在 BMC 里直接运行，逐项输出 PASS / FAIL，覆盖系统服务、传感器和阈值、IPMI 常规命令、风扇 OEM 状态读取（默认不改转速或持久化设置）、Redfish 和网页、RTC、MTD 分区等，同时把 journal、dmesg、D-Bus 树等日志打包。参数 `0` 表示检查 `run-qemu.sh` 的模拟器（默认），`1` 表示物理板；默认只读，结果分为 PASS / FAIL / SKIP / INFO（`SKIP` 表示需要额外操作，不能当成通过），有 FAIL 时退出码为 1。检查按已安装的板级配置核对各路 ADC、温度、风扇和已绑定的 PSU，主机关机时跳过只在开机时有效的读数。只有显式设置 `CEB_CHECK_CLEAR_LOGS=1` 才会清除事件日志。

```bash
ceb-gnrd-check 0                                 # 在 BMC 里运行；开机后等约 1 分钟再跑（ipmid 要等传感器稳定）
BMC_PASSWORD='你的密码' ceb-gnrd-check 0           # root 密码不是默认值时
scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz .   # 在 Ubuntu 上取回日志包（QEMU）
```

报告在 `/tmp/ceb-gnrd-check/report.txt`，诊断包在 `/tmp/ceb-gnrd-check.tar.gz`；重复运行会覆盖上一份，并发运行由 `/run/ceb-gnrd-check.lock` 阻止。报告只代表运行时的当前检查结果。接口元数据正常不等于数据路径全部通过；POST history nonempty 的 FAIL 表示当前保留历史为空，需要结合 Host 状态和本次启动是否收到 POST 判断。

### 1. 构建后先在 QEMU 里检查

```bash
systemctl --failed --no-pager                 # QEMU 缺少 KCS、eSPI、PECI 等硬件，对应服务失败属预期
journalctl -b -p err --no-pager | tail -40
ip addr show eth0                              # QEMU 里 DHCP 第一个租约应为 192.168.185.200
cat /etc/os-release | head                     # VERSION_ID 应为 2.2.0；ipmitool mc info 的 Firmware Revision 应为 2.02
ipmitool mc info                               # Manufacturer Name CTOPAI，Product Name CEB-GNR-D
```

网页逐项点开：菜单里不应再有 SNMP / 清除密钥 / LDAP / 资源管理；风扇页应列出 6 个风扇；SOL 页应能输入；KVM 页应有“全屏”按钮。

### 2. 上板后重点验证

| 项目 | 命令 / 方法 |
| :--- | :--- |
| eSPI | `dmesg \| grep -i espi`；`cat /sys/kernel/debug/*espi*/regs`；对照分析仪抓包 |
| PHY | U-Boot：`mdio list`；Linux：`dmesg \| grep -i -E "phy\|mdio"`、`ethtool -S eth0`、`iperf3` |
| PSU | 插 1 个和 2 个模块各验证：`journalctl -u ceb-gnrd-psu-detect`；`ipmitool sdr` 里应有 PSUn_Temp，`ls /sys/class/hwmon/*/temp*_input` 核对 temp2 确实是电源温度 |
| 电源按键 | `journalctl -u ceb-gnrd-power-button-log -f`；`ipmitool sel list \| tail -3` |
| 告警灯 | 电压越限、温度到 UNR、CPU_MAX_TEMP / DIMM_MAX_TEMP 到 Upper Critical、watchdog 超时、BIOS 启动超过 600 秒各验证一次（共用一个灯，阈值告警恢复后清除，BIOS 超时在后续 POST complete 成功后清除，watchdog 超时重启 BMC 才清除；没有其他故障时熄灭）；`busctl get-property xyz.openbmc_project.LED.GroupManager /xyz/openbmc_project/led/groups/enclosure_fault xyz.openbmc_project.Led.Group Asserted` 应随告警翻转，`cat /sys/class/leds/fault/brightness` 对应亮灭 |
| 风扇 | `busctl tree xyz.openbmc_project.EntityManager \| grep -i pid`；`busctl tree xyz.openbmc_project.FanSensor | grep fanpwm`；网页保存后查看 `journalctl -u ceb-gnrd-fan-settings`；OEM 命令：`ipmitool raw 0x30 0x01`、`ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01`（再读一次确认），失败时 `journalctl -u phosphor-ipmi-host` |
| KCS | BMC：`ls /dev/ipmi-kcs3`、`journalctl -u phosphor-ipmi-kcs@ipmi-kcs3`；主机侧：`ipmitool -I open mc info` |
| NC-SI | 主机 POST 完成并经过 5 秒就绪等待后 `ip -br addr show eth1`、`journalctl -t ceb-gnrd-ncsi`（看有没有重试）；主机关机后接口应被关闭 |
| SEL / 时间 | 制造电压和温度越限，`ipmitool sel list` 里应有事件和解除事件；按文件大小轮转后确认最老的记录被淘汰（不使用固定 2100 条限制）；断电重启后 `date`、`ipmitool sel time get` 应保持 RTC 的时间 |
| U-Boot | 按需恢复默认环境，并恢复两路生产 MAC 后 `saveenv`，确认 `printenv bootcmd` 是 `run bootspi`；`run netupdate` 后 `reset` |
| BMC 状态 | `obmcutil state`（`Device Available` 取决于 BMC 是否为 Ready） |

---

### 3. 日常 BMC 日志检查（只读）

在 BMC控制台执行，以下输出均为本次启动的状态：

```sh
cat /etc/os-release
systemctl --failed --no-pager
journalctl -b -p warning --no-pager -o short-monotonic -n 300
journalctl -b -k --no-pager -o short-monotonic |
grep -Ei 'panic|oops|call trace|out of memory|oom|timeout|error|fail|squashfs'
ipmitool sel elist
```

完整本次日志：`journalctl -b --no-pager -o short-monotonic`，可用MobaXterm保存串口输出。跨普通重启的警告文本看 `/var/log/bmc-system.log` 及轮转文件；`journalctl -b -1`不保证可用，因为journal在RAM。若根文件系统挂载前panic，采集U-Boot到panic的串口输出，无法在该次启动里运行journalctl。

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
| U-Boot 找不到 `.dtb` | 2019.04 需要把 `ast2600-ceb-gnrd.dtb` 登记进 `arch/arm/dts/Makefile`（已放进 `0001-ceb-gnrd-board-device-tree-network-and-environment.patch`） |
| 网页编译 `Unexpected token` | 模板字符串反引号丢失，补丁里的 JS 要逐字核对 |
| `entity-manager: Probe statement failed to parse: True`，电压、风扇、温度等传感器一个都没有 | Entity-Manager 配置里的 `"Probe"` 只认大写的 `"TRUE"` / `"FALSE"`，写成 `"True"` 整份配置会被拒绝；用 `journalctl -b -p err \| grep -i entity` 看 |
| `aspeed-g6-pwm-tach: Failed to create fan -22`，`fansensor: failed to find match for .../fanN_input` | 6.18 的 PWM/TACH 驱动要求风扇子节点写 `tach-ch` 和 `pwms = <&pwm_tach N 40000 0>`，旧写法（`reg`、`aspeed,fan-tach-ch`）会让它失败 |
| `xyz.openbmc_project.LED.GroupManager.service: start operation timed out`，identify 灯不工作 | 这个版本的 LED 管理器只读 `/usr/share/phosphor-led-manager/led-group-config.json`（或 `/etc/phosphor-led-manager/` 下的同名文件），找不到就一直等 Entity-Manager；用 `phosphor-led-manager_%.bbappend` 把板级 `led.json` 装成这个文件名 |
| `ipmitool mc info` 固件版本 `0.00`、网页运行版本 `--`，`xyz.openbmc_project.Software.BMC.Updater` 不存在 | BMC 镜像更新守护进程没有自启（updater 包整体设了 `SYSTEMD_AUTO_ENABLE = "disable"`），它同时提供 BMC 版本对象和固件上传后端；在 bbappend 里为它单独建 `multi-user.target.wants` 软链接 |
| `ModuleNotFoundError: No module named 'xml'` | `python3-dbus-fast` 配方没带 `python3-xml` 等运行依赖，用到它的 Python 服务要在自己的 `RDEPENDS` 里补 |
| `pin L26 already requested by ...mdio` | EVB 设备树默认启用 `mdio0` 至 `mdio3`，只保留用到的 `mdio1`，其余禁用，否则占用 I2C12 的引脚 |
| 风扇设置写入报 `Invalid argument` | Entity-Manager 可能在内存值已更新后返回错误；服务回读确认，再请求重载控制，失败回滚。Pid 使用 Fan0 Control–Fan5 Control，不能与 SYS_FAN0–5同名；不能只用属性值相等就判定 PID 已加载 |
| `ipmitool raw 0x30 0x01` 返回 `0xCE`，服务日志有 `can't concat list to bytearray` | dbus-fast 的 `ay` 返回值必须是 `bytes`，不是整数列表 |
| 网页调 D-Bus REST 方法报 `Invalid method arg type` | 板级 bmcweb 补丁 `0009-ceb-gnrd-fix-dbus-rest-method-arguments.patch` 修复标量参数编码；风扇页仍用包含完整动作的无参数 ApplyFan 方法，避免共享未完成设置 |
| 开机后约一分钟内 `ipmitool sensor` 只有 2 个传感器，日志有 `Failed to update sensor map for threshold sensor` | ipmid 在传感器的阈值接口出现前去读；`phosphor-ipmi-host` 的 drop-in 让它等传感器数量稳定后再启动 |
| Redfish `FirmwareVersion` 为空、网页 BMC 版本 `--`，但 `busctl` 里版本对象存在 | bmcweb 默认从 `/xyz/openbmc_project/software/bmc/functional` 取版本，经典更新服务发布在 `/xyz/openbmc_project/software/functional`；`bmcweb_%.bbappend` 里设 `-Dredfish-updateservice-use-dbus=disabled`（`strings /usr/bin/bmcweb \| grep -c software/bmc/functional` 非 0 说明用的是新路径） |
| `swampd`：`Must have one stepwise point`，风扇不按温度调速 | Entity-Manager 把整数数组（`[40, 50, ...]`）以 `at` 发布，pid-control 读不到，`Stepwise` 的 `Reading`/`Output` 要写成带小数点的 `40.0` |
| 启动日志里有 `mmc0: Failed to initialize a non-removable card` | EVB 设备树启用了 eMMC/SD；本板没有，U-Boot 和 Linux 设备树里都把 `emmc`、`sdhci` 相关节点禁用 |
| `patch-fuzz` 警告出现在 `phosphor-ipmi-host` | 手写补丁的上下文不对；按真实源码重新生成补丁（`0001` 已重新生成） |
| `os-release.bb: git describe --dirty ... No names found` | 检查源码仓库标签是否完整，按需 `git fetch --tags origin`；已有 `2.00-golden-release` 注释标签不要在新提交上重建。发行版显示版本由 DISTRO_VERSION决定，确保 local.conf选ctopai-openbmc且BBLAYERS含meta-ctopai |
| 告警灯服务日志反复出现 `Unable to read host boot GPIOs: Command '['gpioget', 'gpiochip0', '172']' returned non-zero exit status 1` | 第 172 号线是 `BMC_CPU_PWRGD`，已被 x86-power-control 独占请求，`gpioget` 会报设备忙。告警灯服务改为读 D-Bus 的 `xyz.openbmc_project.State.Chassis` `CurrentPowerState`（x86-power-control 根据这根线发布的状态）；`BMC_BIOS_BOOT_OK` 现在也是 x86-power-control 的 `PostComplete`，同样改读 `OperatingSystemState`，告警灯服务不再直接读任何 GPIO |
| `wrong LCONF_VERSION (has 8, expecting 7)` | 发行版文件 `ctopai-openbmc.conf` 在 `meta-ctopai` 层里，而旧的 `build/ceb-gnrd/conf/bblayers.conf` 只列了 `meta-ceb-gnrd`，没有 `meta-ctopai`；`DISTRO` 找不到发行版文件时 BitBake 不报错（可选包含），`LAYER_CONF_VERSION` 就退回 oe-core 默认的 7（`phosphor-base.inc` 里设的是 8）。把 `meta-ctopai` 加进 `BBLAYERS`（`. setup ceb-gnrd` 会自动补），或在 `bblayers.conf` 里手动加一行 `/home/test/openbmc/meta-ctopai \` |
| `ipmitool sel list` 一直是 "SEL has no entries"，但 journal 里有 `sel-logger ... threshold assert` | rsyslog 没有读 journal：默认只加载 `imuxsock`，拿不到 `MESSAGE_ID`、`IPMI_SEL_*` 字段，`/var/log/ipmi_sel` 就从来没被写入。`rsyslog_%.bbappend` 里要 `PACKAGECONFIG:append = " imjournal"`（Intel 参考平台同样这么做）；开机日志里应有 `imjournal`，没有 `Acquired UNIX socket ... syslog` 之外的输入就说明没生效 |
| `ipmitool sel list` 有记录，但网页 “Event logs” 是空的 | 网页读的是 Redfish 事件日志 `/var/log/redfish`（格式 `<时间> <MessageId>,<参数>`），和 IPMI 的 SEL（`/var/log/ipmi_sel`）是两个文件。需要 rsyslog 有一条规则，把带 `REDFISH_MESSAGE_ID` 的 journal 条目写进去（`rsyslog_%.bbappend` 安装的 `ceb-gnrd-redfish.conf`，Intel 参考平台同样的规则，同样依赖 `imjournal`）。只有 bmcweb 注册表里有的消息 ID 才会显示 |
| `do_rootfs: Group render has never been defined` | 来自 `rootfs-postcommands.bbclass` 的 `systemd_sysusers_check`，核对 `/usr/lib/sysusers.d/*.conf` 声明的组是否都在 `/etc/group`。`render` 组本来由 `udev` 包创建，但 meta-phosphor 的 `systemd_%.bbappend` 有意把 `udev` 从 `USERADD_PACKAGES` 里去掉（为了让 udev 不依赖 `shadow`，能放进 initramfs，BMC 没有 `/dev/dri`），所以这个告警是预期的，无影响，忽略 |
| `unable to read id index table` / init panic | SquashFS根文件系统挂载失败；核对编程器文件是否为完整64MiB `.static.mtd`、起始地址0、芯片型号和高地址区域，整片读回与源文件比较；系统尚未启动时采集串口日志 |
| `Invalid logsize. Default to 16kB` | obmc-console 的 logsize使用十进制字节数；当前配置为65536，日志在 `/run`，旧 `64K` 配置不适用 |
| Host Off期间CPU/DIMM没有读数 | 正常断电不应作为失读恢复/故障；核对实际Chassis DC状态及固件版本，Host On失读仍保留保护输入 |
| timesync1不存在而NTP未启用 | 当前板级网络补丁在NTP禁用时跳过查询；启用NTP时才核对服务与配置 |
| `systemd: Failed to set watchdog pretimeout_governor to 'panic'` | `aspeed_wdt` 不支持预超时，内核不提供 `pretimeout_governor`（打开 `CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC` 没有用）；`systemd-conf` 里同名的 `40-hardware-watchdog.conf` 覆盖 meta-phosphor 的那个，去掉 `RuntimeWatchdogPreSec` / `RuntimeWatchdogPreGovernor` |

### 3. 修改网页补丁的建议流程

1. 从 GitHub 下载对应版本的网页源码文件，生成改动后的文件。
2. 用工具生成带 3 行上下文的标准补丁（不要手写 hunk 头）。
3. 在构建机上先 `bitbake -c patch webui-vue`，通过后再完整构建。

---

## 九、板卡层实现说明

本章按实际代码入口说明工作机制，硬件引脚与地址见 `port_guide.xlsx`。校对日期为 2026-10-14；工作区包含 `DISTRO_VERSION=2.2.0` 的版本调整。代码存在不等于全部硬件场景已经验证。

### Flash、启动与升级

| 分区 | 起点 | 大小 |
|---|---|---|
| u-boot | 0x00000000 | 0x000e0000 / 896 KiB |
| u-boot-env | 0x000e0000 | 0x00020000 / 128 KiB |
| kernel | 0x00100000 | 0x00900000 / 9 MiB |
| rofs | 0x00a00000 | 0x02800000 / 40 MiB |
| rwfs | 0x03200000 | 0x00e00000 / 14 MiB |

布局来自 Linux DTS、U-Boot DTS以及 `conf/machine/ceb-gnrd.conf`。`FLASH_SIZE=65536`、`FLASH_RWFS_OFFSET:flash-65536=51200` 的单位是 KiB；镜像生成类在写入各段前检查容量，超限会构建失败。

* 默认 `bootcmd=run bootspi`。`run bootnet` 同时加载 `image-kernel` 和 `image-rofs`，根文件系统从 TFTP 加载、写层在 RAM，失败时不回退旧 Flash rootfs。仅手动 `tftpboot fitImage; bootm` 时仍使用本地 rofs。
* `run netupdate` 更新 kernel/rofs，分别检查 9/40 MiB 边界；不更新 U-Boot、环境和 RWFS。更改布局时必须同步镜像生成、两份设备树与 `ceb-gnrd-env.h`。
* 默认网络参数为 ipaddr 192.168.185.200/24、gatewayip 192.168.185.1、serverip 192.168.185.84；它们只用于 U-Boot。Linux eth0 默认 DHCP。QEMU的 TFTP serverip 为 192.168.185.1。
* U-Boot已移除编译默认 ethaddr/eth1addr及缺省补齐，已有保存值仍生效。使用真实板卡生产 MAC；恢复全部默认环境前记录并恢复两路 MAC。更改 DDR/SPL或启动环境默认值，需要更新 U-Boot才能生效。
* BMC分区升级选择写入 `bmc-partitions.txt`，后端验证后暂存到 `/run/initramfs`，重启时由 initramfs更新。kernel/rofs 成对，U-Boot/环境须显式选择。RWFS重写时按通用与板级白名单恢复设置；日志不在保留列表。
* initramfs 检查备份、刷写及恢复的退出状态。失败时停止后续擦写/自动重启，继续喂看门狗并进入串口 `update-recovery#`，保留 `/run/save`；此时正常 Web/SSH 服务不可用。备份失败会在刷写前停止。先排除存储或挂载错误并确认 RAM 备份完整，再用 `/run/initramfs/update --no-flash --no-save-files --restore-files --no-clean-saved-files` 恢复已有备份；该命令不会重刷镜像或用空 RWFS 覆盖备份。确认镜像及配置均已恢复后才手动重启；断电仍会丢失 RAM 备份。
* BIOS上传包需包含完整 64 MiB镜像。`bios-update.sh` 等待稳定 Host Off、持有升级/Host Flash锁，切换 GPIOM1后显式绑定 SPI-NOR，按 `bios-layout.txt` 和用户区域选择刷写。默认不改 nac0/nac1；选中这些区域需确认。解除绑定和恢复所有权后按现有流程请求主机重新上电。
* BIOS Flash 的高电平保持由独立的 `ceb-gnrd-bios-flash-owner.service` 承担；切换前持久保存 `/var/lib/ceb-gnrd/bios-flash-held`，并建立 `/run/ceb-gnrd-bios-flash-held` 互锁。升级失败时，退出清理及服务停止后处理会尝试解绑 SPI-NOR、拉低选择 GPIO，将控制权归还 BIOS；解绑或交还失败时保留互锁。每次 BMC 启动由 `ceb-gnrd-bios-flash-recover.service` 在电源管理启动前核对并交还，即使旧 `/run` 标记已丢失也不跳过。异常恢复不重新拉高选择 GPIO；镜像完整性须另行确认。
* BIOS 所有权异常时，先检查 `journalctl -u 'obmc-flash-host-bios@*' -u ceb-gnrd-bios-flash-owner.service -u ceb-gnrd-bios-flash-recover.service` 并排除 SPI/GPIO/存储错误，再执行 `bios-update.sh --recover-ownership`。恢复命令仅解绑和交还，不要求 Host Off、不刷写或验证镜像；交还及持久标记同步成功后才解除互锁。显式手工恢复成功后会排队启动恢复服务及电源管理，随后用 `systemctl status ceb-gnrd-bios-flash-recover.service xyz.openbmc_project.Chassis.Control.Power@0.service --no-pager` 确认结果。不要直接删除标记或手工停止保持服务来绕过恢复。
* AC 恢复自动开机仍受升级互锁约束：CPLD 升级期间延后执行；BIOS 升级、手工所有权恢复及检测到未完成交还的开机恢复通过 `/run/ceb-gnrd-bios-power-managed` 取消本次启动尚未执行的 AC 恢复。只有成功的 BIOS 升级流程主动请求随后上电；所有权恢复不请求 Host 电源切换，也不更改配置的 AC 恢复策略。
* CPLD使用 `ceb-gnrd-cpld-update.py`、`cpld_jtag.py` 和 `ceb-gnrd-jtag.c`。仅接受批准的 `.bit`格式、IDCODE/feature code及 primary大小；primary最大 384 KiB，不写 Golden区。任务最多 10分钟，要求 Host Off；逐页 Flash readback验证通过才报告成功，随后整板 AC power cycle生效。
* CPLD 服务先注册接口，再初始化重启保护；没有残留的保护配置时直接就绪。有残留时每次清理限时30秒，失败后间隔5秒重试，最多3次。初始化期间及最终失败后均拒绝升级，状态接口保留错误说明；排除 journal 中的错误后重启 `ceb-gnrd-cpld-update.service` 重试。升级期间仍启用重启保护，烧录及校验成功后仍由用户整板 AC power cycle 激活。
* 运行镜像与 Golden镜像的 persist_bit=1 已由板卡负责人确认，并登记在 `cpld-update.json`。`recovery.json` 持久化准确的镜像/Flash哈希及恢复条件，擦除中断后只有匹配的已批准计划才能重试；它不是任意镜像通用解锁。
* BMC/BIOS/CPLD共用固件升级互斥和重启保护；Host Flash期间阻止Host开机/复位及BMC正常重启。升级进程退出时只释放自己的引用，最后一个引用释放后清理重启保护。

### 温度、风扇与告警

* `ceb-gnrd-temp-max.py` 从 hwmon 标签选取 PECI Die/Core和DIMM温度，排除DTS/Tcontrol/Tthrottle/Tjmax/margin等参考值，只发布 CPU_MAX_TEMP和DIMM_MAX_TEMP。
* 每 2秒采样；读值丢失时保留 `max(70°C, 已发布的较高温度)`，有效采样恢复后使用实测温度；确认 Chassis DC Off后清零。独立监控发现采样超过15秒停滞时采用同样保护并停止systemd watchdog报活。
* 本次 DC 周期已发现的温度源、告警和保守温度峰值保存在 `/run/ceb-gnrd-temp-max/protection.json`，用于温度服务重启后的恢复。部分探头失读时不会只凭较凉的剩余探头解除保护；全部已知探头恢复后仍使用实时温度。仅明确观察到 DC Off 才清除历史，状态未知不视为关机；该缓存不跨 BMC 重启保留。
* Functional区分真实测量与保护输入，有限保护输入保持Available供PID使用；阈值评估使用真实采样，失读保留已触发告警，DC Off清除Host温度告警。开机/复位过渡只延迟诊断日志，不延迟散热保护。
* 自动曲线的输入/输出点见 `recipes-phosphor/configuration/entity-manager/ceb-gnrd.json`：CPU 40/50/60/70/80/90°C 对应30/40/50/60/80/100%；DIMM 40/50/60/70/80°C 对应30/40/55/60/100%，下降滞回2°C。PID取两条需求的较高值，区域最低30%。这些配置仍需按实板散热验证。
* `ceb-gnrd-fan-settings.py` 为六个控制器提供串行操作、快照回滚、持久化与控制重载。网页固定值20–100%、步进10%；IPMI接受10–100%。GetFans要求六个控制器的上下限完整、有限且合法；失败时返回ConfigurationUnavailable。
* 固定模式的最终 PWM 使用该风扇配置的占空比，高温和区域 failsafe 不覆盖固定值；温度、传感器故障和告警记录继续工作。同一区域的自适应风扇仍执行温度曲线及 60% failsafe 策略。GetFans 在固定模式返回设置值，在自适应模式返回当前 PWM。
* `ceb-gnrd-fan-owner` 取得 GPIOI6并清除复位保持位；`ceb-gnrd-fan-release` 停止时交还CPLD。Host供电的TACH失读只在确认机箱DC Off时抑制，热复位不能按Host逻辑Off撤销散热检查。
* `ceb-gnrd-alert-led.py` 汇总电压Critical、温度UNR及CPU/DIMM UC、600秒BIOS启动超时和Host watchdog。阈值源暂时消失不当作恢复；故障缓存保留到对应的有效状态明确解除。Host Off清除Host供电传感器的失读状态。
* BIOS 超时先在内存锁存并尝试记录 SEL，再独立保存锁存文件；文件写入失败每 30 秒重试，不中断告警处理或重新开始 600 秒等待。CPU_MAX_TEMP / DIMM_MAX_TEMP 的 UNC、UC、UNR 阈值均只读，IPMI SDR 同样声明不可写。
* BIOS超时在后续POST complete时解除；Host watchdog状态锁存到BMC重启。`enclosure_fault` 映射到GPIOI5的fault LED，告警期间定期重发组状态。
* 常驻 IPMI watchdog 在实际 Chassis DC Off 或 BMC 成功发起硬复位时停掉旧计时器，服务继续提供配置接口，避免旧倒计时影响下一轮 BIOS 启动。POST-only 热复位不触发停表；当前板未接入实体 Reset 输入，不能依此识别独立的外部硬件复位。

### 电源、UID、POST与启动设置

* `power-config-host0.json` 的PowerOk是GPIOV4；PowerOut/ResetOut由x86-power-control独占。实体Power button只通知BMC，实体Reset没有连接BMC，因此IPMI机箱能力查询不假定Power0/Reset0 Enabled可用。
* UID短按保持定位功能；持续5秒读取实际GPIO后请求正常BMC重启，长按释放不再重复定位，启动时已经按住的旧事件不直接当作新长按。
* 来电恢复策略默认AlwaysOn，只在已识别AC上电时应用；单独BMC重启保留Host当前状态。未知复位来源不授权自动主机上电。AC恢复策略触发的自动开机等待Power Good最多60秒（`ACRestorePowerOKWatchdogMs=60000`）；普通开机和电源循环仍使用8秒（`PowerOKWatchdogMs=8000`）。超时仍记录上电失败。
* 同一次BMC启动内，AC恢复任务在 `/run/ceb-gnrd-power-restore-host0/state.json` 保存待执行、已完成或已取消状态。电源服务重启会按原策略、断电前电源状态及原启动截止时间恢复等待；已执行、手动电源操作或BIOS接管所取消的任务不重放。该记录不跨BMC重启保留。
* PSU“预测故障”（`PredictiveFailure`）须连续有效采样保持10秒，且复查仍告警后才更新健康状态和记录事件；恢复、读取失败或供电状态不适用时取消待确认告警。已确认告警恢复时立即解除。严重故障、风扇故障及AC丢失事件不使用此延迟。整机AC断电后若BMC在确认前掉电，则不会记录待确认的预测故障；余电持续超过10秒时仍可能记录。
* PSU 事件连续读失败或读到格式错误时保留已确认告警，不以合成的零值报告恢复；收到有效正常值后才解除。既有供电状态适用规则仍生效，读取失败仍会取消尚未确认的预测故障计时。
* BMC重启原因结合bootstatus与干净关机标记识别；正常shutdown/reboot不因ASPEED watchdog复位机制被直接当作异常watchdog。异常watchdog写入SEL；BMC Ready/正常状态变化按信息级别记录。
* `ceb-gnrd-health` 为ObjectMapper、EntityManager、bmcweb和ipmid设置Restart/启动限制及OnFailure=Quiesce；本层fan-settings、temp-max、alert-led、boot-progress仅自动重启，不因单次服务失败直接Quiesce。Quiesced自动BMC重启限制为1次，计数保存在RWFS，正常运行15分钟后清零；持久故障留待人工处理。上游未报活的服务不能靠WatchdogSec检测卡死，本层notify服务按各自主循环报活。
* POST捕获来自port0x80。`phosphor-post-code-manager_%.bbappend` 设置max-boot-cycle-count=1、每轮512条。Host重启边界清理上一轮；服务/BMC重启恢复当前轮；`ceb-gnrd-post-history-limit.py` 检查并迁移历史/元数据。
* `ceb-gnrd-boot-progress.py` 与网页共用参考码表，按4F/60、90、AD、AF/AE等锚点区分阶段。DXE之前重用的B0–BF按Intel RC参考含义；D*/E*/50/55等未匹配平台子码保留原值，不能只按AMI数值区间断言错误。POST complete表示OSStart，不证明OS已运行。
* 一次性Boot override由BIOS通过IPMI读取并消费；网页按实际override启用状态显示已消费后的None，刷新时保留尚未保存的表单修改，并避免保存无关设置时重新启用旧目标。None表示不覆盖BIOS自身启动顺序。诊断时读取boot/one_time Enabled及`ipmitool chassis bootparam get 5`，不能只看网页复选框，也不把POST进度当作自动清除override的证明。

### 网络、PSU、RTC与串口

* eth0是MAC2/DT mac1，RTL8211FS-CG地址1，rgmii-id，CPLD驱动PHY reset。eth1是MAC3/DT mac2的NC-SI；U-Boot禁用eth1。
* networkd生成和迁移物理网卡配置使用硬件Path：eth0=platform-1e680000.ethernet，eth1=platform-1e670000.ethernet；VLAN和其他接口仍按适用名称匹配。禁用网络管理器persist-mac/sync-mac，旧MAC覆盖清理保留IP等设置。
* networkd启动前先在 `/run` 生成并比较迁移结果；配置已符合要求时不写RWFS。只有确需迁移时才原子替换配置，写入失败仍阻止启动，避免旧NC-SI策略提前拉起网口。
* NC-SI要求Chassis On、POST complete和NICEnabled，等待5秒再拉起；初始无carrier每30秒重试，三次后每300秒慢恢复。已获取carrier后的网线掉线保留已发现通道，等待内核恢复；状态未知时不主动拉起或重探测。
* 内核区分发现 NC-SI 通道与完成版本/能力初始化。初次探测为空或中途失败时，下次接口启动会重试；不完整通道不参与配置，正常通道和选择策略保留，重复探测复用已初始化的过滤表。
* `ceb-gnrd-psu-detect.sh` 启动一次探测i2c-7。未绑定时读取STATUS_WORD，失败才尝试STATUS_BYTE；MFR_MODEL规范化为MEGCRPS800AOP/CRPS800AOP时选megcrps800，否则选generic pmbus。已绑定设备用驱动锁保护的hwmon/debugfs路径，不强制绕过驱动访问PAGE/PEC。
* Generic PMBus并不保证每家PSU提供相同通道；PSUSensor按实际驱动hwmon标签发布输入/输出电压、功率和温度。换框/换模块后需重启BMC重新检测；没有定时热插拔切换。未配置PSU在位/冗余/阈值告警。
* NCT3015Y-R在i2c-9/0x6f，作为rtc0；RTC sync最多等待3秒，总启动超时5秒。NTP禁用时网络管理器不请求不存在的timesync服务；启用后需要核对配置与同步结果。
* 默认SOL配置 `server.ttyS2.conf`，物理UART3，115200；VUART1单独console-id，对应`server.ttyVUART0.conf`。Web可切换来源，IPMI/SSH默认连接物理端点；UART5/ttyS4留给BMC调试。

### 日志、诊断、证书与保留

* JFFS2不适合二进制journal的可写mmap，本板journal为RAM存储，限8MiB/8文件。rsyslog将warning及以上写入持久`bmc-system.log`（512KiB、5旧文件），SEL 15KiB/1旧文件，Redfish 64KiB/1旧文件。轮转在写入时执行，保留条数取决于记录大小。
* `ceb-gnrd-sel-logrotate` 名称保留，但当前定时任务是RWFS空间监控；启动清理限制旧诊断文件，不删除用户设置。SEL事件元数据保留sensor type/number/event type/generator ID；标准`ipmitool event`格式与手动Platform Event兼容。
* SEL logger 重启后收到的第一条阈值变化可为触发或解除，不能因内存中缺少旧触发而丢弃恢复事件；后续相同状态仍去重。网页事件列表读取所有 Redfish 分页，列表与“全部导出”使用同一完整结果；分页失败保留上次完整列表。
* BMC普通重启保留持久日志；升级选择重写RWFS时日志不在白名单。用户、网络、机器ID等由通用白名单保留；板级白名单另含时区、主机名、SSH/HTTPS/CA证书、风扇设置、CPLD recovery和bmcweb持久数据。整片编程器烧录/恢复出厂不等同普通升级保留流程。
* CA证书以单张文件和hash links为持久化来源；批量上传包仅用于校验/暂存，提交前删除快照。旧bundle按独立文件迁移，不恢复已经删除的CA。普通服务退出保留CA文件；显式Delete/DeleteAll仍删除；批量替换保留事务回滚。
* `ceb-gnrd-check 1` 对实板进行当前状态只读诊断并保存报告/日志包。关机时跳过配置为 On/ChassisOn/BiosPost 的实时读数检查，仍检查六个风扇 SDR 是否存在。检查通过不代替Host侧功能、时序或压力验证；显式CEB_CHECK_CLEAR_LOGS=1才授权删除事件日志。
* `bmc-hw-dump` 提供只读GPIO/pinmux/I2C/eSPI/KCS/VUART/网络/MTD等转储。原始信号球位来自硬件契约和pinctrl，不应从端口表反推已完成实板验证。

### 已知限制与实板确认

* 未配置PLDM BIOS属性/更新、SMBIOS系统/CPU/DIMM清单和DCMI；MCTP独立保留。BIOS版本未上报时Web显示N/A。
* biosconfig-manager提供BMC侧配置服务，实际UEFI BIOS菜单交互仍需BIOS协议与属性上报配合，不能因守护进程已安装就宣称远程Setup可用。
* 虚拟媒体仅支持本地浏览器ISO；内部菜单切换保持连接，浏览器刷新/关闭会断开。后台标签休眠也可能造成WebSocket断流。独立挂载窗口方案未实现。
* 虚拟媒体代理的 `splice()` 遇到 `EINTR`/`EAGAIN` 时返回信号和 I/O 处理循环，正常子进程退出不再被当作连接故障；真实断流仍结束会话。
* KVM键释放失败可能造成重复字符，尚未修复；收到ENOLINK时需核对主机视频输出状态。
* 仍需确认GPIO在异常复位/升级中断时的板级电平、CPLD交接/Golden恢复、不同PSU通道、风扇曲线负载、RGMII/NC-SI时序、RTC断电保持和UART/VUART主机端实际输入输出。
* D3V0_BAT0应按实际R542/Q39焊接与分压校准。已确认的PHY地址1及当前rgmii-id配置不再列为地址2待猜测。

### IPMI里的板卡版本

PCB_VER[2:0]的原始电平编码为 `(PCB_VER2 << 2) | (PCB_VER1 << 1) | PCB_VER0`，值0–7，置于IPMI AUX固件版本第四个字节；CFG_VER0不计入PCB版本。相关GPIO名称与球位见端口表。

## 十、代码目录与文件清单（`meta-ceb-gnrd`）

路径均相对于 `meta-ctopai/meta-ceb-gnrd/`。以下索引按当前工作区文件校对；未引用的草稿补丁不表示已经进入构建。配方的 `SRC_URI` 决定补丁和源文件是否参与构建。

### `conf/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `conf/layer.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `conf/machine/ceb-gnrd.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `conf/templates/default/bblayers.conf.sample` | 开发资料或配方数据 |
| `conf/templates/default/conf-notes.txt` | 开发资料或配方数据 |
| `conf/templates/default/local.conf.sample` | 开发资料或配方数据 |

### `recipes-bsp/u-boot/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-bsp/u-boot/files/0001-ceb-gnrd-board-device-tree-network-and-environment.patch` | ceb-gnrd: board device tree, default network and environment |
| `recipes-bsp/u-boot/files/0002-ceb-gnrd-pass-boot-reset-cause-to-linux.patch` | aspeed: pass the original reset cause to Linux |
| `recipes-bsp/u-boot/files/0003-ceb-gnrd-fill-missing-default-mac.patch` | ceb-gnrd: migrate network boot defaults before NIC probe |
| `recipes-bsp/u-boot/files/0004-ceb-gnrd-reserve-32m-vga-before-ddr-init.patch` | ram: aspeed: allow a board VGA reservation before DDR init |
| `recipes-bsp/u-boot/files/0005-ceb-gnrd-sync-runtime-network-after-env-migration.patch` | ceb-gnrd: synchronize runtime IPs after environment migration |
| `recipes-bsp/u-boot/files/0006-ceb-gnrd-simplify-network-boot-environment.patch` | ceb-gnrd: use standard network variables for TFTP boot |
| `recipes-bsp/u-boot/files/0007-ceb-gnrd-network-boot-rootfs-migration.patch` | CEB-GNRD: migrate factory bootnet to TFTP rootfs |
| `recipes-bsp/u-boot/files/ast2600-ceb-gnrd.dts` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-bsp/u-boot/files/ceb-gnrd-ddr4.cfg` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-bsp/u-boot/files/ceb-gnrd-env.h` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-bsp/u-boot/files/ceb-gnrd-network.cfg` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-bsp/u-boot/u-boot-aspeed-sdk_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-connectivity/jsnbd/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-connectivity/jsnbd/files/0001-stop-reaping-on-echild-and-serialize-gadget-cleanup.patch` | nbd-proxy: handle ECHILD and finish setup before teardown |
| `recipes-connectivity/jsnbd/files/0002-nbd-client-explicit-default-export.patch` | nbd-proxy: specify the default export for NBD 3.27 |
| `recipes-connectivity/jsnbd/files/state_hook` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-connectivity/jsnbd/jsnbd_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-core/busybox/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-core/busybox/busybox_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-core/busybox/files/ceb-gnrd-netboot.cfg` | 板级硬件、运行配置或接口数据；以文件内容为准 |

### `recipes-core/systemd/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-core/systemd/files/0001-hostnamed-allow-networkd-transient-hostname-without-polkit.patch` | hostnamed: allow networkd transient hostname without polkit |
| `recipes-core/systemd/files/10-ceb-gnrd-eth0.network` | 开发资料或配方数据 |
| `recipes-core/systemd/files/20-ceb-gnrd-boot-mac.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/20-ceb-gnrd-eth1-ncsi.network` | 开发资料或配方数据 |
| `recipes-core/systemd/files/40-hardware-watchdog.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/50-ceb-gnrd-console.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/60-ceb-gnrd-coredump-limits.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/60-ceb-gnrd-journal-limits.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/60-ceb-gnrd-pstore-limits.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-core/systemd/files/ceb-gnrd-clear-network-mac.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-core/systemd/systemd-conf_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-core/systemd/systemd_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-devtools/qemu/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-devtools/qemu/qemu-system-native_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-extended/rsyslog/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-extended/rsyslog/files/ceb-gnrd-redfish.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-extended/rsyslog/files/ceb-gnrd-rotate-log.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-extended/rsyslog/files/ceb-gnrd-system-errors.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-extended/rsyslog/files/rsyslog-override.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-extended/rsyslog/rsyslog_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-kernel/linux/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-kernel/linux/files/0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch` | soc: aspeed: add AST2600 eSPI peripheral I/O enablement |
| `recipes-kernel/linux/files/0002-hwmon-add-AST2600-chassis-intrusion-driver.patch` | hwmon: add AST2600 chassis intrusion latch support |
| `recipes-kernel/linux/files/0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch` | peci: add GNR and GNR-D package and DIMM temperature profiles |
| `recipes-kernel/linux/files/0004-pmbus-ratelimit-optional-device-probe-message.patch` | hwmon: pmbus: rate-limit unavailable status-register warning |
| `recipes-kernel/linux/files/0005-usb-gadget-hid-classify-endpoint-shutdown.patch` | usb: gadget: hid: classify cancelled IN requests |
| `recipes-kernel/linux/files/0006-ncsi-accept-initial-deselect-response.patch` | ncsi: accept discovery deselect replies before package registration |
| `recipes-kernel/linux/files/0007-peci-retry-response-in-progress.patch` | peci: retry response-in-progress completion code |
| `recipes-kernel/linux/files/0008-hwmon-add-megcrps800-psu-driver.patch` | hwmon: add MEG-CRPS800AOP telemetry driver |
| `recipes-kernel/linux/files/0009-ncsi-retry-empty-discovery-on-start.patch` | ncsi: retry discovery after an empty initial probe |
| `recipes-kernel/linux/files/0010-spi-aspeed-select-data-width-for-user-writes.patch` | spi: aspeed: select data bus width for user-mode writes |
| `recipes-kernel/linux/files/0011-ncsi-handle-idle-work-and-report-invalid-responses.patch` | ncsi: tolerate idle work and describe rejected responses |
| `recipes-kernel/linux/files/0012-spi-nor-detect-board-bios-on-explicit-bind.patch` | spi-nor: auto-detect CEB-GNRD BIOS only after explicit driver binding |
| `recipes-kernel/linux/files/aspeed-ceb-gnrd.dts` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-kernel/linux/files/ceb-gnrd-jtag.c` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-kernel/linux/files/espi-peci.cfg` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-kernel/linux/linux-aspeed_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/bios/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/bios/biosconfig-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/bios/files/0001-ceb-gnrd-bound-bios-attribute-storage.patch` | Bound persistent storage on CEB-GNRD |

### `recipes-phosphor/buttons/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/buttons/ceb-gnrd-power-button-log.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/buttons/files/0001-ceb-gnrd-uid-long-press-bmc-reboot.patch` | buttons: reboot BMC after a physical UID hold of five seconds |
| `recipes-phosphor/buttons/files/10-ceb-gnrd-wait-buttons.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/buttons/files/ceb-gnrd-power-button-log.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/buttons/files/ceb-gnrd-power-button-log.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/buttons/files/ceb-gnrd-wait-buttons.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/buttons/files/gpio_defs.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/buttons/obmc-phosphor-buttons_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/certificate/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/certificate/files/0001-ceb-gnrd-bound-certificate-storage.patch` | Bound persistent storage on CEB-GNRD |
| `recipes-phosphor/certificate/files/0002-ceb-gnrd-transactional-authority-replacement.patch` | certificates: stage and validate complete authority replacements |
| `recipes-phosphor/certificate/files/0003-ceb-gnrd-use-individual-authorities-as-persistent-store.patch` | Use individual authority certificates as the persistent store |
| `recipes-phosphor/certificate/phosphor-certificate-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/configuration/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/configuration/ceb-gnrd-hardware-contract.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/configuration/ceb-gnrd-yaml-config.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/configuration/ceb-gnrd-yaml-config/ceb-gnrd-ipmi-fru-properties.yaml` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/configuration/ceb-gnrd-yaml-config/ceb-gnrd-ipmi-fru.yaml` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/configuration/entity-manager/0001-ceb-gnrd-fru-device-allow-eeprom-sized-write.patch` | fru-device: allow a FRU image as large as the EEPROM |
| `recipes-phosphor/configuration/entity-manager/0002-ceb-gnrd-verify-fru-eeprom-write.patch` | fru-device: verify EEPROM writes before reporting success |
| `recipes-phosphor/configuration/entity-manager/0003-ceb-gnrd-skip-static-platform-inventory-events.patch` | inventory: skip unidentified static CEB-GNRD platform events |
| `recipes-phosphor/configuration/entity-manager/0004-ceb-gnrd-megcrps800-schema.patch` | configuration: accept MEGCRPS800 PSU type |
| `recipes-phosphor/configuration/entity-manager/0005-ceb-gnrd-classify-busy-fru-scan-addresses.patch` | fru-device: classify driver-owned addresses as normal scan skips |
| `recipes-phosphor/configuration/entity-manager/0006-ceb-gnrd-gpio-presence-empty-discovery.patch` | gpio-presence: treat an empty initial configuration scan as discovery |
| `recipes-phosphor/configuration/entity-manager/0007-ceb-gnrd-generic-crps-schema.patch` | configuration: accept externally managed CRPS PSU slots |
| `recipes-phosphor/configuration/entity-manager/ceb-gnrd.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/configuration/entity-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/configuration/files/ceb-gnrd-hardware-contract.yaml` | 板级硬件、运行配置或接口数据；以文件内容为准 |

### `recipes-phosphor/console/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/console/files/server.ttyS2.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/console/files/server.ttyVUART0.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/console/obmc-console_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/dump/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/dump/files/0001-ceb-gnrd-collect-chassis-interface-and-ram-sol.patch` | dreport: select Chassis interface and collect board RAM console logs |
| `recipes-phosphor/dump/phosphor-debug-collector_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/fans/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/fans/ceb-gnrd-fan-services.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/fans/ceb-gnrd-fan-settings.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/fans/ceb-gnrd-temp-max.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/fans/files/0001-ceb-gnrd-ignore-fan-tach-failures-while-host-off.patch` | pid: skip host-powered tach failures while host is off |
| `recipes-phosphor/fans/files/0002-ceb-gnrd-deduplicate-failsafe-state-logs.patch` | pid: separate sensor diagnostics from zone failsafe transitions |
| `recipes-phosphor/fans/files/0003-ceb-gnrd-quiet-fan-logs-during-host-transitions.patch` | pid: quiet transient telemetry logs and report zone transitions once |
| `recipes-phosphor/fans/files/0004-ceb-gnrd-use-dc-power-for-thermal-gating.patch` | pid: distinguish actual chassis power-off from host reset states |
| `recipes-phosphor/fans/files/10-ceb-gnrd-temp-max.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-owner.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-owner.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-release.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-settings.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fans/files/ceb-gnrd-fan-settings.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/fans/files/ceb-gnrd-temp-max.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fans/files/ceb-gnrd-temp-max.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/fans/files/com.ctopai.CebGnrd.FanSettings.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/fans/files/com.ctopai.CebGnrd.TempMax.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/fans/phosphor-pid-control_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/flash/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/flash/ceb-gnrd-cpld-update.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/flash/ceb-gnrd-cpld-update/files/ceb-gnrd-cpld-update.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/flash/ceb-gnrd-cpld-update/files/ceb-gnrd-cpld-update.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/flash/ceb-gnrd-cpld-update/files/com.ctopai.CebGnrd.CpldUpdate.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/flash/ceb-gnrd-cpld-update/files/cpld-update.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/flash/ceb-gnrd-cpld-update/files/cpld_jtag.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/flash/phosphor-software-manager/0001-ceb-gnrd-bmc-update-partition-selection.patch` | static: stage only selected CEB-GNRD BMC partitions |
| `recipes-phosphor/flash/phosphor-software-manager/0002-ceb-gnrd-lock-bmc-staging-against-other-updaters.patch` | static: serialize BMC staging with BIOS and CPLD programming |
| `recipes-phosphor/flash/phosphor-software-manager/0003-ceb-gnrd-share-firmware-reboot-guard.patch` | update: share reboot protection across activations and programmers |
| `recipes-phosphor/flash/phosphor-software-manager/10-ceb-gnrd-reboot-guard-cleanup.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/flash/phosphor-software-manager/bios-layout.txt` | 开发资料或配方数据 |
| `recipes-phosphor/flash/phosphor-software-manager/bios-update.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/flash/phosphor-software-manager/obmc-flash-host-bios@.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/flash/phosphor-software-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/fru/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/fru/ceb-gnrd-fru.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/fru/files/ceb-gnrd-fru-init.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/fru/files/ceb-gnrd-fru-init.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fru/files/ceb-gnrd-fru-rescan.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/fru/files/ceb-gnrd-fru-rescan.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/fru/files/default-fru.bin` | 开发资料或配方数据 |

### `recipes-phosphor/health/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/health/ceb-gnrd-health.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/health/files/10-ceb-gnrd-reboot-limit.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/health/files/10-ceb-gnrd-restart-own.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/health/files/10-ceb-gnrd-restart.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/health/files/ceb-gnrd-quiesce-reboot-clear.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/health/files/ceb-gnrd-quiesce-reboot-clear.timer` | systemd 服务/定时器定义 |
| `recipes-phosphor/health/files/ceb-gnrd-quiesce-reboot-limit.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/health/files/ceb-gnrd-wdt-reset-log.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/health/files/ceb-gnrd-wdt-reset-log.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |

### `recipes-phosphor/images/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/images/obmc-phosphor-image.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/initrdscripts/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/initrdscripts/files/0001-ceb-gnrd-tftp-rootfs-for-network-boot.patch` | CEB-GNRD: select TFTP rootfs and RAM overlay for bootnet |
| `recipes-phosphor/initrdscripts/files/ceb-gnrd-netboot.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/initrdscripts/files/ceb-gnrd-update-skip-u-boot.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/initrdscripts/files/ceb-gnrd-whitelist` | 开发资料或配方数据 |
| `recipes-phosphor/initrdscripts/obmc-phosphor-initfs.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/interfaces/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/interfaces/bmcweb_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/interfaces/files/0001-ceb-gnrd-delete-single-file-event-log.patch` | eventlog: support single file-entry deletion without shifting IDs |
| `recipes-phosphor/interfaces/files/0002-ceb-gnrd-async-virtual-media-proxy-cleanup.patch` | virtual-media: reap nbd-proxy without blocking the web loop |
| `recipes-phosphor/interfaces/files/0003-ceb-gnrd-virtual-media-receive-backpressure.patch` | virtual-media: drain proxy writes before reading more messages |
| `recipes-phosphor/interfaces/files/0004-ceb-gnrd-report-boot-id-for-update-monitor.patch` | service root: report BMC boot ID for update monitoring |
| `recipes-phosphor/interfaces/files/0005-ceb-gnrd-allow-same-origin-kvm-fullscreen.patch` | http: allow same-origin KVM fullscreen |
| `recipes-phosphor/interfaces/files/0006-ceb-gnrd-fix-bmcweb-state-directory.patch` | bmcweb: clear invalid state directory in root mode |
| `recipes-phosphor/interfaces/files/0007-ceb-gnrd-bound-persistent-session-storage.patch` | bound persistent sessions and event subscription payloads |
| `recipes-phosphor/interfaces/files/0008-ceb-gnrd-cpld-update-interlock.patch` | update: serialize CPLD programming with Web BMC/BIOS uploads |
| `recipes-phosphor/interfaces/files/0009-ceb-gnrd-fix-dbus-rest-method-arguments.patch` | dbus-rest: convert scalar method arguments and extract data array |
| `recipes-phosphor/interfaces/files/0010-ceb-gnrd-cpld-bit-json-upload-limit.patch` | dbus-rest: allow bounded CPLD bitstream JSON uploads |
| `recipes-phosphor/interfaces/files/0011-ceb-gnrd-existing-image-build-info.patch` | managers: expose existing os-release build identifiers |

### `recipes-phosphor/inventory/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/inventory/ceb-gnrd-bmc-inventory.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/inventory/files/0001-ceb-gnrd-bound-inventory-cache.patch` | Bound persistent storage on CEB-GNRD |
| `recipes-phosphor/inventory/files/10-ceb-gnrd-bmc-inventory.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/inventory/files/ceb-gnrd-bmc-inventory.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/inventory/files/ceb-gnrd-bmc-inventory.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/inventory/files/ceb-gnrd-wait-bmc-inventory.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/inventory/files/com.ctopai.CebGnrd.BmcInventory.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/inventory/phosphor-inventory-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/ipmi/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-fan.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-fru-read-inventory-native.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-i2c.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-sensor-inventory-native.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-sensors/config.yaml` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/ipmi/ceb-gnrd-ipmi-whitelist-native.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/ipmi/files/0001-ceb-gnrd-report-board-revision-in-mc-info.patch` | apphandler: expose CEB-GNRD PCB revision in mc info AUX byte |
| `recipes-phosphor/ipmi/files/0001-ceb-gnrd-stable-rmcp-bmc-guid.patch` | net-ipmi: use the same stable BMC GUID as local IPMI and Redfish |
| `recipes-phosphor/ipmi/files/0001-ipmitool-fru-add-gen-command.patch` | fru: add an interactive gen command |
| `recipes-phosphor/ipmi/files/0002-ceb-gnrd-show-upper-non-recoverable-threshold.patch` | sensors: show the upper non-recoverable threshold |
| `recipes-phosphor/ipmi/files/0002-ipmitool-add-ceb-gnrd-product-name.patch` | strings: add the CEB-GNR-D product name |
| `recipes-phosphor/ipmi/files/0003-ceb-gnrd-fru-area-is-the-whole-eeprom.patch` | storagecommands: make the FRU commands work with FruDevice for a whole EEPROM |
| `recipes-phosphor/ipmi/files/0004-ceb-gnrd-ipmi-version-and-system-guid.patch` | ipmi: guard version lookup and provide an unset host GUID fallback |
| `recipes-phosphor/ipmi/files/0005-ceb-gnrd-compatible-chassis-and-optional-vr.patch` | ipmi: support x86 button masking and optional chassis resources |
| `recipes-phosphor/ipmi/files/0006-ceb-gnrd-platform-event-channel-and-metadata.patch` | ipmi: parse platform events by channel and retain raw SEL metadata |
| `recipes-phosphor/ipmi/files/0007-ceb-gnrd-report-front-panel-masking-unsupported.patch` | ipmi: report unmaskable board front-panel buttons |
| `recipes-phosphor/ipmi/files/0008-ceb-gnrd-report-live-non-recoverable-alarms.patch` | ipmi: report live UNR alarm, event support and recovery |
| `recipes-phosphor/ipmi/files/10-ceb-gnrd-wait-sensors.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/ipmi/files/ceb-gnrd-ipmi-fan/fan_oem.cpp` | 开发资料或配方数据 |
| `recipes-phosphor/ipmi/files/ceb-gnrd-ipmi-fan/meson.build` | 开发资料或配方数据 |
| `recipes-phosphor/ipmi/files/ceb-gnrd-ipmi-whitelist.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/ipmi/files/ceb-gnrd-wait-sensors.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/ipmi/files/generate_i2c_allowlist.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/ipmi/ipmitool_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/ipmi/phosphor-ipmi-config.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/ipmi/phosphor-ipmi-config/dev_id.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/ipmi/phosphor-ipmi-fru/obmc/eeproms/system/chassis/motherboard` | 开发资料或配方数据 |
| `recipes-phosphor/ipmi/phosphor-ipmi-fru_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/ipmi/phosphor-ipmi-host_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/ipmi/phosphor-ipmi-net_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/leds/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/leds/ceb-gnrd-alert-led.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/leds/ceb-gnrd-espi-heartbeat.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/leds/ceb-gnrd-led-manager-config-native.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/leds/files/0001-led-accept-supported-short-names-without-warning.patch` | led: log supported short names at debug level |
| `recipes-phosphor/leds/files/ceb-gnrd-alert-led.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/leds/files/ceb-gnrd-alert-led.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/leds/files/ceb-gnrd-espi-heartbeat.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/leds/files/led.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/leds/files/wait-for-espi-driver.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/leds/phosphor-led-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/leds/phosphor-led-sysfs_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/logging/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/logging/files/0001-ceb-gnrd-bound-event-entry-storage.patch` | Bound variable-length persistent data on CEB-GNRD |
| `recipes-phosphor/logging/files/0002-ceb-gnrd-journal-event-severity.patch` | logging: preserve committed event severity in journal |
| `recipes-phosphor/logging/phosphor-logging_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/network/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/network/ceb-gnrd-ncsi.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/network/files/0001-ceb-gnrd-preserve-ncsi-manual-activation.patch` | network: preserve manual activation for host-powered NC-SI |
| `recipes-phosphor/network/files/0002-ceb-gnrd-skip-timesyncd-query-when-ntp-disabled.patch` | network: skip timesyncd server query when NTP is disabled |
| `recipes-phosphor/network/files/0003-ceb-gnrd-match-physical-networks-by-hardware-path.patch` | network: match board physical NICs by verified hardware path |
| `recipes-phosphor/network/files/ceb-gnrd-ncsi.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/network/files/manage-ncsi-link.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/network/phosphor-network_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/packagegroups/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/packagegroups/packagegroup-ceb-gnrd-apps.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/packagegroups/packagegroup-obmc-apps.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/pldm/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/pldm/pldm_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/psu/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/psu/ceb-gnrd-psu-detect.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/psu/files/ceb-gnrd-psu-detect.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/psu/files/ceb-gnrd-psu-detect.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/psu/files/psusensor-psu-detect.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |

### `recipes-phosphor/rtc/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/rtc/ceb-gnrd-rtc-sync.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/rtc/files/ceb-gnrd-rtc-sync.service` | systemd 服务/定时器定义 |

### `recipes-phosphor/sel-logger/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/sel-logger/ceb-gnrd-sel-logrotate.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/sel-logger/files/0001-ceb-gnrd-log-non-recoverable-threshold-events.patch` | threshold monitor: log non-recoverable threshold events |
| `recipes-phosphor/sel-logger/files/0002-ceb-gnrd-bound-sel-file-at-write-time.patch` | rsyslog: rotate SEL in the writer before it grows indefinitely |
| `recipes-phosphor/sel-logger/files/0003-ceb-gnrd-preserve-platform-event-metadata.patch` | sel: persist original platform event sensor and event identifiers |
| `recipes-phosphor/sel-logger/files/ceb-gnrd-log-storage-cleanup.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/sel-logger/files/ceb-gnrd-log-storage-cleanup.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/sel-logger/files/ceb-gnrd-sel-logrotate.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/sel-logger/files/ceb-gnrd-sel-logrotate.timer` | systemd 服务/定时器定义 |
| `recipes-phosphor/sel-logger/files/ceb-gnrd-storage-budget.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/sel-logger/phosphor-sel-logger_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/sensors/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/sensors/dbus-sensors_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/sensors/files/0001-reuse-i2c-device-by-config-path-and-guard-psu-io.patch` | sensors: reuse I2C devices by configuration path and guard PSU I/O |
| `recipes-phosphor/sensors/files/0002-ceb-gnrd-megcrps800-psu.patch` | psu: consume externally managed MEGCRPS800 devices |
| `recipes-phosphor/sensors/files/0003-ceb-gnrd-gate-chassis-adc-and-delayed-alarms.patch` | sensors: gate initial chassis samples and recheck delayed alarms |
| `recipes-phosphor/sensors/files/0004-ceb-gnrd-persistent-intrusion-enable.patch` | intrusion: persist opt-in chassis monitoring |
| `recipes-phosphor/sensors/files/0005-fan-use-resolved-pwm-enable-path.patch` | fan: derive enable path from the resolved PWM file |
| `recipes-phosphor/sensors/files/0006-psu-log-filtered-devices-at-debug-level.patch` | psu: log unsupported scanned devices at debug level |
| `recipes-phosphor/sensors/files/0007-psu-log-cancelled-poll-timer-at-debug-level.patch` | psu: treat cancelled polling timers as normal lifecycle events |
| `recipes-phosphor/sensors/files/0008-fan-log-unmatched-inputs-at-debug-level.patch` | fan: log unmatched scanned inputs at debug level |
| `recipes-phosphor/sensors/files/0009-psu-log-unmatched-devices-at-debug-level.patch` | psu: log unmatched discovered devices at debug level |
| `recipes-phosphor/sensors/files/0010-hwmon-temp-skip-peci-auxiliary-devices.patch` | hwmon-temp: skip PECI auxiliary devices before I2C parsing |
| `recipes-phosphor/sensors/files/0011-guard-optional-mode-and-intrusion-discovery.patch` | sensors: fix SpecialMode interface and optional discovery |
| `recipes-phosphor/sensors/files/0012-psu-recover-cleared-grouped-alarms.patch` | psu: recover grouped alarms when the last source clears |
| `recipes-phosphor/sensors/files/0013-ceb-gnrd-consume-auto-selected-crps-driver.patch` | psu: consume CRPS devices selected during startup |

### `recipes-phosphor/settings/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/settings/files/0001-ceb-gnrd-bound-persistent-setting-text.patch` | Bound variable-length persistent data on CEB-GNRD |
| `recipes-phosphor/settings/phosphor-settings-manager/settings.override.yml` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/settings/phosphor-settings-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/state/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/state/ceb-gnrd-boot-progress.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/state/files/0001-ceb-gnrd-post-history-warm-boot-cycle.patch` | post codes: preserve all values and use host events for cycles |
| `recipes-phosphor/state/files/0001-ceb-gnrd-recognize-clean-watchdog-reboots.patch` | state: recognize orderly software reboots performed by watchdog |
| `recipes-phosphor/state/files/0002-ceb-gnrd-block-bmc-reboot-during-host-flash.patch` | state: interlock BMC reboots with BIOS and CPLD programming |
| `recipes-phosphor/state/files/0002-ceb-gnrd-post-history-latest-cycle-only.patch` | post codes: discard previous archives when the next cycle starts |
| `recipes-phosphor/state/files/0003-ceb-gnrd-post-history-resume-current-cycle.patch` | post codes: preserve the current host cycle across BMC and service restarts |
| `recipes-phosphor/state/files/60-ceb-gnrd-post-history.conf` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/state/files/ami-aptio-v-post-codes.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/state/files/ceb-gnrd-boot-progress.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/state/files/ceb-gnrd-boot-progress.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/state/files/ceb-gnrd-post-history-limit.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/state/phosphor-post-code-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |
| `recipes-phosphor/state/phosphor-state-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/users/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/users/files/0001-ceb-gnrd-bound-ldap-persistent-config.patch` | Bound variable-length persistent data on CEB-GNRD |
| `recipes-phosphor/users/phosphor-user-manager_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/utils/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/utils/ceb-gnrd-check.bb` | 板级配方及依赖/安装配置 |
| `recipes-phosphor/utils/files/bmc-hw-dump.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/utils/files/ceb-gnrd-check.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `recipes-phosphor/utils/files/ceb-gnrd-check.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |

### `recipes-phosphor/watchdog/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/watchdog/phosphor-watchdog/phosphor-watchdog-host-cycle.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/watchdog/phosphor-watchdog/phosphor-watchdog-host-poweroff.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/watchdog/phosphor-watchdog/phosphor-watchdog-host-reset.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/watchdog/phosphor-watchdog/phosphor-watchdog.service` | systemd 服务/定时器定义 |
| `recipes-phosphor/watchdog/phosphor-watchdog_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-phosphor/webui/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-phosphor/webui/files/0001-ceb-gnrd-limit-webui-languages.patch` | ceb-gnrd: limit web UI languages to English and Chinese |
| `recipes-phosphor/webui/files/0002-ceb-gnrd-add-simplified-chinese-locale.patch` | ceb-gnrd: add simplified Chinese WebUI locale |
| `recipes-phosphor/webui/files/0003-ceb-gnrd-add-fan-control-page.patch` | ceb-gnrd: add WebUI fan speed control page |
| `recipes-phosphor/webui/files/0004-ceb-gnrd-remove-resource-management-power.patch` | webui: remove SNMP Alerts, Key clear, LDAP and Resource management |
| `recipes-phosphor/webui/files/0006-ceb-gnrd-kvm-full-screen.patch` | webui: add a full screen button to the KVM console |
| `recipes-phosphor/webui/files/0007-ceb-gnrd-factory-reset-bmc-only.patch` | webui: factory reset page only offers the BMC reset |
| `recipes-phosphor/webui/files/0008-ceb-gnrd-inventory-supported-tables-only.patch` | webui: keep only the inventory tables that have a backend |
| `recipes-phosphor/webui/files/0009-ceb-gnrd-remove-overview-power-card.patch` | overview: remove the power information card |
| `recipes-phosphor/webui/files/0010-ceb-gnrd-firmware-single-bank.patch` | firmware: remove the backup image cards |
| `recipes-phosphor/webui/files/0011-ceb-gnrd-dumps-bmc-only.patch` | dumps: offer BMC dump only |
| `recipes-phosphor/webui/files/0012-ceb-gnrd-policies-remove-vtpm-rtad.patch` | policies: remove the Virtual TPM and RTAD switches |
| `recipes-phosphor/webui/files/0013-ceb-gnrd-firmware-update-progress.patch` | firmware: update progress, BIOS flash region selection |
| `recipes-phosphor/webui/files/0014-ceb-gnrd-firmware-cards-side-by-side.patch` | firmware: BMC and BIOS cards side by side, wider update form |
| `recipes-phosphor/webui/files/0015-ceb-gnrd-sensors-discrete-table.patch` | sensors: analog and discrete sensors on two tabs |
| `recipes-phosphor/webui/files/0016-ceb-gnrd-post-codes-newest-first.patch` | post codes: newest first |
| `recipes-phosphor/webui/files/0017-ceb-gnrd-sensors-pagination.patch` | sensors: paginate the analog sensor table |
| `recipes-phosphor/webui/files/0018-ceb-gnrd-firmware-progress-survives-page-change.patch` | firmware: keep the update progress when the page is left |
| `recipes-phosphor/webui/files/0019-ceb-gnrd-factory-reset-bmc-wording.patch` | factory reset: no server wording, no shutdown warning |
| `recipes-phosphor/webui/files/0020-ceb-gnrd-overview-firmware-card.patch` | overview: firmware card without backup and system firmware version |
| `recipes-phosphor/webui/files/0021-ceb-gnrd-refresh-server-power-operation-state.patch` | webui: refresh power state while waiting for server operations |
| `recipes-phosphor/webui/files/0022-ceb-gnrd-event-log-explicit-columns.patch` | Event logs: remove unsupported status columns and avoid empty fields |
| `recipes-phosphor/webui/files/0023-ceb-gnrd-event-log-actions-heading.patch` | Event logs: label the actions column |
| `recipes-phosphor/webui/files/0024-ceb-gnrd-refresh-live-status-pages.patch` | webui: refresh live sensors and status views |
| `recipes-phosphor/webui/files/0025-ceb-gnrd-close-virtual-media-websocket-on-stop.patch` | webui: close virtual media sessions and cancel pending reads |
| `recipes-phosphor/webui/files/0026-ceb-gnrd-chunk-virtual-media-read-replies.patch` | virtual-media: split NBD replies into bounded WebSocket messages |
| `recipes-phosphor/webui/files/0027-ceb-gnrd-post-code-table-sort-api.patch` | post codes: use current table sorting API |
| `recipes-phosphor/webui/files/0028-ceb-gnrd-event-logs-newest-first.patch` | event logs: default to newest first with current table API |
| `recipes-phosphor/webui/files/0029-ceb-gnrd-bmc-update-partition-selection.patch` | firmware: select BMC partitions with explicit bootloader confirmation |
| `recipes-phosphor/webui/files/0030-ceb-gnrd-bmc-update-completion-notification.patch` | firmware: recognize BMC reboot and retain completion notification |
| `recipes-phosphor/webui/files/0031-ceb-gnrd-sol-source-selection.patch` | SOL: use physical UART in output-only mode |
| `recipes-phosphor/webui/files/0032-ceb-gnrd-kvm-restore-fullscreen-layout.patch` | webui: restore KVM layout after leaving fullscreen |
| `recipes-phosphor/webui/files/0033-ceb-gnrd-chassis-intrusion-switch.patch` | inventory: add persistent chassis intrusion switch |
| `recipes-phosphor/webui/files/0034-ceb-gnrd-timezone-ui-language.patch` | webui: format timezone names using the UI locale |
| `recipes-phosphor/webui/files/0035-ceb-gnrd-boot-checkpoint-details.patch` | webui: show BIOS boot checkpoints and raw POST codes |
| `recipes-phosphor/webui/files/0036-ceb-gnrd-colored-navigation-icons.patch` | ceb-gnrd: use colored function icons in primary navigation |
| `recipes-phosphor/webui/files/0037-ceb-gnrd-refresh-confirmed-time-mode.patch` | ceb-gnrd: reflect confirmed Manual/NTP mode after saving |
| `recipes-phosphor/webui/files/0038-ceb-gnrd-colored-openbmc-logos.patch` | ceb-gnrd: use blue and green OpenBMC logos throughout WebUI |
| `recipes-phosphor/webui/files/0039-ceb-gnrd-responsive-date-time-settings.patch` | webui: bound date-time loading and avoid fixed NTP-stop wait |
| `recipes-phosphor/webui/files/0040-ceb-gnrd-cpld-firmware-update.patch` | webui: add CPLD firmware updates through guarded JTAG service |
| `recipes-phosphor/webui/files/0041-ceb-gnrd-ami-post-code-descriptions.patch` | webui: interpret AMI Aptio V POST codes and boot progress |
| `recipes-phosphor/webui/files/0042-ceb-gnrd-post-code-sequence-context.patch` | webui: interpret reused POST codes within each boot cycle |
| `recipes-phosphor/webui/files/0043-ceb-gnrd-post-code-concise-descriptions.patch` | webui: keep POST descriptions to documented meanings |
| `recipes-phosphor/webui/files/0044-ceb-gnrd-post-code-export-json-array.patch` | webui: export all POST logs as one JSON array |
| `recipes-phosphor/webui/files/0045-ceb-gnrd-firmware-upload-hints.patch` | firmware: disable update until a package is selected and show formats |
| `recipes-phosphor/webui/files/0046-ceb-gnrd-post-code-source-context.patch` | webui: distinguish AMI and Intel reference POST meanings by sequence |
| `recipes-phosphor/webui/files/0047-ceb-gnrd-firmware-hints-above-upload.patch` | firmware: put package format guidance above Add file |
| `recipes-phosphor/webui/files/0048-ceb-gnrd-date-time-input-alignment.patch` | date-time: align manual inputs and separate timezone text |
| `recipes-phosphor/webui/files/0049-ceb-gnrd-post-code-latest-cycle-only.patch` | post code logs: expose only the latest host boot cycle |
| `recipes-phosphor/webui/files/0050-ceb-gnrd-firmware-upload-mutual-exclusion.patch` | firmware: disable uploads mutually during BMC BIOS or CPLD updates |
| `recipes-phosphor/webui/files/0051-ceb-gnrd-firmware-upload-labels.patch` | firmware: use firmware format guidance without an image file heading |
| `recipes-phosphor/webui/files/0052-ceb-gnrd-cpld-update-firmware-heading.patch` | firmware: add matching update firmware heading above CPLD upload |
| `recipes-phosphor/webui/files/0053-ceb-gnrd-overview-existing-build-info.patch` | overview: show running-image build ID and Git version |
| `recipes-phosphor/webui/files/0054-ceb-gnrd-bios-missing-version-na.patch` | firmware: show N/A for an unavailable BIOS version |
| `recipes-phosphor/webui/files/0055-ceb-gnrd-hide-overview-source-version.patch` | overview: remove source version text from firmware card |
| `recipes-phosphor/webui/files/0056-ceb-gnrd-virtual-media-survives-navigation.patch` | virtual-media: retain browser mounts across menu navigation |
| `recipes-phosphor/webui/files/0057-ceb-gnrd-consumed-boot-override.patch` | webui: refresh consumed boot overrides and save only edits |
| `recipes-phosphor/webui/files/0058-ceb-gnrd-fix-event-export-and-fan-load-status.patch` | webui: encode event JSON arrays and clear recovered fan load errors |
| `recipes-phosphor/webui/files/0059-ceb-gnrd-fan-speed-ten-percent-steps.patch` | webui: offer fixed fan speed in ten percent steps |
| `recipes-phosphor/webui/files/zh-CN.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-phosphor/webui/webui-vue_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `recipes-x86/chassis/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `recipes-x86/chassis/files/0001-ceb-gnrd-add-force-power-button-off-method.patch` | x86-power-control: expose force-off pulse while host is off |
| `recipes-x86/chassis/files/0002-ceb-gnrd-own-bus-name-for-the-exported-buttons.patch` | x86-power-control: do not share the Chassis.Buttons bus name |
| `recipes-x86/chassis/files/0003-ceb-gnrd-apply-power-restore-only-on-ac-boot.patch` | power-control: apply restore policies only on AC boot |
| `recipes-x86/chassis/files/0004-ceb-gnrd-log-dc-events-on-chassis-transitions.patch` | power-control: log DC events on chassis transitions |
| `recipes-x86/chassis/files/0005-ceb-gnrd-report-forced-warm-reset-state.patch` | power control: report forced warm reset to host-state consumers |
| `recipes-x86/chassis/files/0006-ceb-gnrd-block-host-start-during-firmware-programming.patch` | power: block software start and reset during host flash programming |
| `recipes-x86/chassis/files/power-config-host0.json` | 板级硬件、运行配置或接口数据；以文件内容为准 |
| `recipes-x86/chassis/x86-power-control_%.bbappend` | 上游配方的板级追加；列出实际源文件和补丁 |

### `tools/`

| 文件 | 用途 / 配置入口 |
|---|---|
| `tools/bmc-hw-dump.md` | 开发资料或配方数据 |
| `tools/expand-to-tutorial-build.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/EVENTLOG-DELETE-FIX.md` | 开发资料或配方数据 |
| `tools/qemu/FAN-OWNER-GLOB-FIX.md` | 开发资料或配方数据 |
| `tools/qemu/GUI-HEARTBEAT-RESET.md` | 开发资料或配方数据 |
| `tools/qemu/README.md` | 开发资料或配方数据 |
| `tools/qemu/VUART-STARTUP-FIX.md` | 开发资料或配方数据 |
| `tools/qemu/build-qemu.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/diagnose-bmc.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/diagnose-virtual-media.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/diagnose-web.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/host-sim.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/host_io.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/kvm/os.jpg` | 开发资料或配方数据 |
| `tools/qemu/kvm/post.jpg` | 开发资料或配方数据 |
| `tools/qemu/kvm/test-pattern.jpg` | 开发资料或配方数据 |
| `tools/qemu/log-sink.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/panel.html` | 开发资料或配方数据 |
| `tools/qemu/panel_services.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/qemu/patches/0001-aspeed-scu-report-the-AST2600-AHB-clock-HCLK.patch` | aspeed/scu: report the AST2600 AHB clock (HCLK) |
| `tools/qemu/patches/0002-aspeed-pwm-model-the-fan-tachometers-and-wire-the-co.patch` | aspeed/pwm: model the fan tachometers and wire the controller on AST2600 |
| `tools/qemu/patches/0003-hw-misc-add-bmc-host-sim-a-simulated-host-behind-the.patch` | hw/misc: add bmc-host-sim, a simulated host behind the Aspeed BMC GPIOs |
| `tools/qemu/patches/0004-aspeed-adc-settable-input-voltages.patch` | aspeed/adc: settable input voltages |
| `tools/qemu/patches/0005-aspeed-gpio-keep-pin-levels-and-reset-tolerant-outpu.patch` | aspeed/gpio: keep pin levels and reset tolerant outputs across a reset |
| `tools/qemu/patches/0006-hw-sensor-add-crps-psu-a-generic-CRPS-PMBus-power-su.patch` | hw/sensor: add crps-psu, a generic CRPS PMBus power supply |
| `tools/qemu/patches/0007-aspeed-peci-answer-as-an-Intel-CPU-at-address-0x30.patch` | aspeed/peci: answer as an Intel CPU at address 0x30 |
| `tools/qemu/patches/0008-bmc-host-sim-the-CPU-answers-PECI-only-while-the-hos.patch` | bmc-host-sim: the CPU answers PECI only while the host is on |
| `tools/qemu/patches/0009-hw-rtc-add-the-Nuvoton-NCT3018Y-NCT3015Y-I2C-RTC.patch` | hw/rtc: add the Nuvoton NCT3018Y/NCT3015Y I2C RTC |
| `tools/qemu/patches/0010-aspeed-AST2600-VUART-and-LPC-snoop-port-80h-POST-cod.patch` | aspeed: AST2600 VUART and LPC snoop (port 80h POST codes) |
| `tools/qemu/patches/0011-bmc-host-sim-POST-codes-on-port-80h-during-POST.patch` | bmc-host-sim: POST codes on port 80h during POST |
| `tools/qemu/patches/0012-aspeed-read-only-fan-speed-PWM-duty-and-POST-code-pr.patch` | aspeed: read-only fan speed, PWM duty and POST code properties |
| `tools/qemu/patches/0013-aspeed-gpio-a-pin-switched-to-output-drives-the-last.patch` | aspeed/gpio: a pin switched to output drives the last written value |
| `tools/qemu/patches/0014-aspeed-AST2600-video-engine-with-a-still-picture-for.patch` | aspeed: AST2600 video engine with a still picture for the BMC KVM |
| `tools/qemu/patches/0015-aspeed-gpio-read-only-gpio-dir-N-properties.patch` | aspeed/gpio: read-only gpio-dir[N] properties |
| `tools/qemu/patches/0016-aspeed-video-signal-a-mode-detection-when-the-input-.patch` | aspeed/video: signal a mode detection when the input appears |
| `tools/qemu/patches/0017-aspeed-adc-compensation-mode-always-reads-half-scale.patch` | aspeed/adc: compensation mode always reads half scale |
| `tools/qemu/patches/0018-aspeed-integrate-espi-usb-chassis-and-video.patch` | aspeed: integrate host eSPI, USB vHub, chassis and VGA models |
| `tools/qemu/patches/0019-aspeed-peci-model-GNR-D-channel-temperatures.patch` | aspeed/peci: model GNR-D package and channel temperatures |
| `tools/qemu/patches/0020-aspeed-adc-keep-the-channel-values-to-10-bits.patch` | aspeed/adc: keep the channel values to 10 bits |
| `tools/qemu/patches/0020-bmc-host-sim-consume-force-off-pulse-while-off.patch` | bmc-host-sim: do not boot on release of an off-state force pulse |
| `tools/qemu/patches/0021-aspeed-fix-video-detection-and-usb-ep0-handshakes.patch` | aspeed: preserve no-signal detection and USB EP0 handshakes |
| `tools/qemu/patches/0022-aspeed-remove-unrealized-legacy-vuart.patch` | aspeed: remove the replaced legacy VUART child |
| `tools/qemu/patches/0023-bmc-host-sim-add-board-reset-button.patch` | bmc-host-sim: add board reset button independent of BMC GPIO |
| `tools/qemu/patches/0024-aspeed-preserve-power-on-and-watchdog-reset-causes.patch` | aspeed: model power-on and watchdog reset event logs |
| `tools/qemu/patches/0025-at24c-separate-backing-size-from-address-space.patch` | at24c: allow aligned backing for byte-addressed 256-byte blocks |
| `tools/qemu/patches/0026-ftgmac100-ceb-gnrd-rtl8211-and-intel-ncsi.patch` | ftgmac100: add opt-in RTL8211FS and Intel NC-SI test profiles |
| `tools/qemu/run-qemu.sh` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/tests/test_cpld_bit_update.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/tests/test_cpld_jtag_transport.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
| `tools/tests/test_fan_failure_recovery.py` | 板级实现或辅助程序；服务安装入口见所在配方 |
