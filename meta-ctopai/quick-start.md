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
  -nic user,net=192.168.185.0/24,host=192.168.185.1,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623
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
| 手动 TFTP 前要做什么 | 无（`serverip` 默认就是 .84） | 手动 `setenv serverip 192.168.185.1` |
| `mii`、PHY 寄存器、RGMII 时序 | 真实硬件，**必须上板验证** | 模拟的（所有 PHY 地址都应答，页寄存器读出全 0），不能代表真实板子 |

**镜像**：`fitImage` 只含内核、设备树和 initramfs，手动网络启动只替换这一部分，根文件系统仍用本地闪存的 rofs。文件在 `build/ceb-gnrd/tmp/deploy/images/ceb-gnrd/fitImage`，文件名必须保持 `fitImage`。

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
  -nic user,net=192.168.185.0/24,host=192.168.185.1,tftp=/srv/tftp,hostfwd=tcp:127.0.0.1:8443-192.168.185.200:443,hostfwd=tcp:127.0.0.1:2222-192.168.185.200:22,hostfwd=udp:127.0.0.1:2623-192.168.185.200:623
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
2. 烧入新编译的 U-Boot 和镜像后，**第一次要重置 U-Boot 环境**（环境存在闪存里；如果以前保存过带 `tftpboot` 的旧 `bootcmd`，会盖住新默认值，板子仍会先走网络），并设置 MAC（不设会每次启动随机）：

```
env default -a
setenv ethaddr 02:00:00:00:00:01
saveenv
reset
```

   `env default -a` 不可用时，手动设置：`setenv bootcmd 'run bootspi'; setenv ipaddr 192.168.185.200; setenv netmask 255.255.255.0; setenv gatewayip 192.168.185.1; setenv serverip 192.168.185.84; saveenv`。
3. 重启后应直接从本地闪存启动，不出现 TFTP。要手动网络启动时，在 `Hit any key to stop autoboot` 时按任意键，然后执行 `tftpboot 0x83000000 fitImage` 和 `bootm 0x83000000`，串口日志里应出现 `TFTP from server 192.168.185.84; our IP address is 192.168.185.200` 和 `Bytes transferred`。
4. 出问题时的排查（**只适用于物理板子**）：
   * Ubuntu：`ip -br addr`（地址在接 BMC 的网卡上）、`sudo ufw status`（放开 UDP 69）、`sudo journalctl -u tftpd-hpa -f`（看有没有收到请求）。
   * 抓包（局域网流量大，用 BMC 的 MAC 过滤）：`sudo tcpdump -i <网卡> -n -e ether host 02:00:00:00:00:01`。
   * 链路已 `up` 但 ARP/TFTP 不通：用 `sudo ethtool -s <网卡> speed 100 duplex full autoneg on` 把链路限制到 100M 再试；100M 通而 1000M 不通，说明是 RGMII 延时问题，可在 U-Boot 里用 `mii write 2 0x1f 0xd08` 后读写 `0x11`（TX 延时，bit 8）和 `0x15`（RX 延时，bit 3）做实验，确认后再改设备树的 `phy-mode`。

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
3. 取 `image-rofs`（变量 `netupdate_rofs`），检查大小不超过 44 MiB，`sf update` 写到 `0xa00000`。
4. 成功后提示 `Network update done, run reset`。

**不会改动**：U-Boot 本体和环境（`0x000000` 到 `0x0fffff`，所以保存的 `ethaddr`、`bootcmd` 不丢）、可写分区 `rwfs`（`0x3600000`，所以用户配置不丢）。

**准备**：把 `image-kernel`、`image-rofs` 放进 TFTP 目录（`sudo cp -L <deploy 目录>/image-kernel /srv/tftp/` 和 `image-rofs`，`chmod 644`）。物理主板上 `serverip` 默认就是 192.168.185.84；QEMU 里先 `setenv serverip 192.168.185.1`（并且 QEMU 要带 `tftp=`）。文件名不同时，用 `setenv netupdate_kernel <名字>` / `setenv netupdate_rofs <名字>` 修改。

**注意**：
* 写入过程中断电可能让镜像损坏；这条命令不写 U-Boot，所以即使失败，也还能进入 U-Boot 重新执行。
* 旧的已保存环境会盖住新默认值，第一次需要 `env default -a; saveenv`（见 4.3）。
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

> 下表只描述代码里已经实现的内容；标 ⚠️ 的项还没有上板验证或存在疑问，详见 `port_guide.xlsx` 底部红字的“待澄清”区块。

### 1. 板级硬件与固件布局

| 项目 | 现状 |
| :--- | :--- |
| BMC Flash | W25Q512JV 64 MiB；布局：U-Boot / 环境变量 / 内核 9 MiB / **ROFS 44 MiB** / **RWFS 10 MiB**（`FLASH_RWFS_OFFSET:flash-65536 = "55296"`，设备树分区与之对应） |
| 管理网口 `eth0` | MAC2 + RTL8211FS（`rgmii`，PHY 地址 2 ⚠️，复位由 CPLD 控制），静态 `192.168.185.200/24`，网关 `192.168.185.1`，DNS `192.168.185.1 / 223.5.5.5 / 223.6.6.6` |
| NC-SI 网口 `eth1` | MAC3，Linux 里默认 DHCP；E810 没有待机供电，主机上电后由 `ceb-gnrd-ncsi` 自动拉起（30 秒内没有链路就 down/up 重试，每 30 秒一次，最多 3 次），主机关机时关闭；U-Boot 里不启动该口 |
| MAC 地址 | 保存在 U-Boot 环境变量 `ethaddr` / `eth1addr`，固件升级不会擦除 `u-boot-env` 分区 |
| ADC | 内部 2.5 V 参考电压；`D3V0_BAT0` 因 R542/Q39 未焊会饱和 ⚠️ |
| eSPI | 仅 Peripheral 通道；驱动带复位恢复、错误计数和 debugfs 日志 ⚠️（见下） |
| RTC / 时间 | AST2600 内部 RTC（无电池）已关闭，板上 NCT3015Y 是 `rtc0`；内核开机校时，`ceb-gnrd-rtc-sync` 兜底（最多等 `/dev/rtc0` 3 秒，启动超时 5 秒；QEMU 里没有 RTC 会等满 3 秒）；BMC 系统时间和 SEL 时间默认来自 RTC |
| 主机 KCS | 设备树 `&kcs3` 带 `aspeed,lpc-io-reg = <0xca2>`（驱动必需），未配 SerIRQ；需要 eSPI 外设通道就绪、BIOS 把 KCS 端口设为 0xCA2 才通 ⚠️ |
| U-Boot | 固定从本地 SPI 闪存启动（`bootcmd = run bootspi`）；默认网络参数与 Linux eth0 一致（用于手动 TFTP）；`run netupdate` 通过 TFTP 更新闪存里的内核和 rofs（见第四章 4.5）；NC-SI 口在 U-Boot 里禁用 |
| PSU | `ceb-gnrd-psu-detect` 每 5 秒探测 0x58/0x59/0x5A，仅为在位模块创建 pmbus 设备；传感器有输入/输出电压、输入/输出功率和 PSUn_Temp（取 pmbus 的 temp2）⚠️ |
| SD / eMMC | 本板没有，U-Boot 和 Linux 设备树都把 `emmc`、`sdhci` 相关节点设为 disabled，开机日志里不再有 `mmc0: Failed to initialize a non-removable card` |
| 硬件看门狗 | AST2600 WDT1 由 systemd 喂狗（`RuntimeWatchdogSec=120s`），复位类型 `soc`（只复位 SoC，不是整颗芯片，避免 GPIO 回到上电状态让 CPLD/主机侧信号抖动 ⚠️ 上板要确认复位期间这些电平稳定）。`aspeed_wdt` 不支持预超时，所以 `systemd-conf` 安装了一个和 meta-phosphor 同名的 `/etc/systemd/system.conf.d/40-hardware-watchdog.conf`（同名文件 /etc 里的覆盖 /usr/lib 里的），只保留 `RuntimeWatchdogSec=120s` 和 `WatchdogDevice`，去掉 `RuntimeWatchdogPreSec`、`RuntimeWatchdogPreGovernor=panic`，否则每次开机都会有 `Failed to set watchdog pretimeout_governor` 提示（曾试过用空赋值清除，systemd 报 `Failed to parse RuntimeWatchdogPreSec=`，不可行）。内核崩溃：`CONFIG_PANIC_ON_OOPS` + `CONFIG_PANIC_TIMEOUT=5`，5 秒后重启；打开了 Magic SysRq（`echo c > /proc/sysrq-trigger` 可以制造崩溃做测试，串口 BREAK 不能触发）。服务恢复（标准做法，`ceb-gnrd-health`）：drop-in `10-ceb-gnrd-restart.conf` 给对象映射器、Entity-Manager、bmcweb、ipmid 和本层的风扇设置、温度最大值、告警灯服务设置 `Restart=always`、启动限制（5 分钟内 5 次）和 `OnFailure=obmc-bmc-service-quiesce@0.target`，服务一直起不来时 phosphor-state-manager 把 BMC 置为 Quiesced，并按 `phosphor-state-manager_%.bbappend` 里打开的 `auto-reboot-on-bmc-quiesce` 自动重启 BMC。上游没有次数限制，这里用 `ceb-gnrd-quiesce-reboot-limit.sh` 限制为**最多自动重启 1 次**（计数存在读写分区，开机 15 分钟后由定时器清零）：重启后同一个故障还在，BMC 就停在 Quiesced 状态，不再自动重启，并写一条 SEL，需要人工处理；上游的守护进程不向 systemd 报活，所以只能恢复崩溃，进程还在但卡死不会被发现，本层自己的三个服务是 `Type=notify` + `WatchdogSec=`，主循环卡死会被重启；`ceb-gnrd-wdt-reset-log` 在没有干净关机标记而 `bootstatus` 显示看门狗复位时写 SEL（在 U-Boot 里 `reset` 也会被记一次）。以上新增部分没有编译、没有验证 |

### 2. GPIO 行为

| GPIO | 行为 |
| :--- | :--- |
| UID 按键 `BMC_UID_BUTTON_N`（GPIOV0） | 低有效，按下切换 identify 灯组；UID 灯 `BMC_UID_LED`（GPIOV1）高有效 |
| CPU 开关机 `BMC_CPU_POWER_BUTTON`（V2）、复位 `BMC_CPU_RESET`（V3） | 低脉冲，由 `x86-power-control` 输出（200 ms / 强制关机 8 s / 复位 500 ms；强制关机脉冲在 `power-config-host0.json` 的 `ForceOffPulseMs`，`bios-update.sh` 里的 `FORCE_OFF_PULSE_S` 要比它大 1 秒） |
| `BMC_CPU_PWRGD`（V4） | 高有效输入，供状态机判断上电 |
| 电源按键输入 `BMC_POWER_BUTTON_INPUT`（GPIOM2） | **只检测**：按下时写 SEL 和日志，不触发开关机，也不直通到 CPU 电源按键输出 |
| 告警灯 `BMC_SYS_ALERT_LED`（GPIOI5） | 内核 LED 名 `fault`，由 phosphor-led-manager 的标准组 `enclosure_fault` 驱动（`ceb-gnrd-alert-led` 只负责置位/清除该组的 `Asserted`，每 30 秒重发一次以防 led-manager 重启丢状态）。电压越限点亮，温度到达 UNR（不可恢复上限）点亮；**CPU_MAX_TEMP / DIMM_MAX_TEMP 到达 Upper Critical（98°C / 85°C）也点亮**，阈值告警解除且没有其他故障时熄灭；BIOS 启动超时（**600 秒**）点亮，后续 POST complete 成功后清除；watchdog 超时锁存点亮，BMC 重启后清除 ⚠️ 没有验证 |
| `BMC_FAN_BMC_OVERRIDE_N`（GPIOI6） | 风扇控制就绪后拉高，BMC 接管风扇；服务停止时拉低交还 CPLD。BMC 复位（看门狗或用户触发）期间 BMC 不能控制风扇，必须交还 CPLD，所以这根脚**不保持**：内核对用户态申请的线都会置位 reset tolerance，`ceb-gnrd-fan-owner` 在占住这根线后用 `devmem` 清掉 `0x1e7800ac` 的 bit6，复位时它回到输入态；清不掉就不接管风扇（留给 CPLD）。正常关机时服务停止，`ceb-gnrd-fan-release` 先把它拉低 ⚠️ 没有在板上验证（复位后这根脚悬空时 CPLD 是否接管风扇要确认） |
| 复位保持（reset tolerance） | AST2600 的 GPIO 每个引脚有 reset tolerance 位，置位的引脚在看门狗 SoC 复位时保持方向和输出值；用户态（x86-power-control、`gpioset`）申请一根线时内核自动置位。`BMC_CPU_POWER_BUTTON`、`BMC_CPU_RESET`、`BMC_BIOS_FLASH_SELECT` 依赖这个行为，在用户触发的 BMC 复位和看门狗复位中保持状态；`BMC_BIOS_FLASH_SELECT` 只在 BIOS 升级时被改变，其他时间 BMC 不碰它 ⚠️ 没有在板上验证 |
| `BMC_HBLED_N`（GPIOP7） | eSPI 驱动就绪后启用内核 heartbeat 触发器 |
| `BMC_BIOS_FLASH_SELECT`（GPIOM1） | BIOS 升级时拉高切给 BMC，等 5 秒后烧写，结束后拉低 |
| `BMC_BIOS_BOOT_OK`（GPIOM7） | x86-power-control 的标准 `PostComplete`（高有效）：拉高时 D-Bus `xyz.openbmc_project.State.OperatingSystem` 的 `OperatingSystemState` 为 `Standby`，否则为 `Inactive`（主机关机时也是 `Inactive`）。主机开着时它的下降沿会进入 x86-power-control 的热复位检查并记一次软复位的重启原因，**不会产生电源脉冲**。告警灯服务读 `OperatingSystemState` 来取消当次 BIOS 启动超时告警 ⚠️ 没有在板上验证 |

### 3. Web 界面

* **已保留**：概要、事件日志、POST Code、转储、清单与 LED（系统/BMC/机箱三张表）、传感器、恢复出厂设置（仅 BMC）、KVM（含全屏）、固件、重启 BMC、SOL、服务器电源操作、虚拟媒体、日期与时间、风扇控制、网络、电源恢复策略、会话、用户管理、策略、证书。
* **已移除**（无后台支持）：转储页的“System dump”选项（只保留 BMC dump）、固件页 BMC 和 BIOS 两处的“备份镜像”卡片以及“切换为运行”（BMC 和 BIOS 都只有一个镜像区）、概览页“电源信息”卡片（功耗读数和功率上限依赖 DCMI 电源支持，本板不提供）、SNMP Alerts、清除密钥、LDAP、策略页的“虚拟 TPM”和“RTAD”开关、资源管理/电源、“仅重置服务器选项”、清单页的 DIMM/风扇/电源/处理器/组件表。
* **转储**：只有 BMC dump（`phosphor-debug-collector`）；转储页走 bmcweb 的 Redfish Dump 服务，需要编译选项 `redfish-dump-log`（已在 `bmcweb_%.bbappend` 里启用，缺了这个选项转储页没有后端）。在 QEMU 里点“开始转储”要约 30 秒才完成，期间再点会报“Another user initiated dump in progress”，点一次后等它完成即可（QEMU 里已验证列表正常）。
* **固件版本**：bmcweb 默认（`redfish-updateservice-use-dbus=enabled`）到 `/xyz/openbmc_project/software/bmc/functional` 找 BMC 版本，而这里用的经典 `phosphor-image-updater` 发布在 `/xyz/openbmc_project/software/functional`，结果 Redfish 的 `FirmwareVersion` 为空、网页 BMC 卡片显示 `--`；`bmcweb_%.bbappend` 里已把该选项设为 `disabled`（同时固件上传走 `/tmp/images`，和经典更新服务一致）⚠️ 没有验证。`journalctl` 里的 `mapperx: Found invalid association` 是 BMC 版本对象的 `inventory` 关联目标路径为空（找不到 BMC 清单对象），只是告警。网页只提供“从浏览器读取镜像文件”（走 bmcweb 的 /vm/0/0 WebSocket → jsnbd → nbd → USB mass storage → 主机 VL805 USB 口）；“从外部服务器读取镜像文件”（CIFS/HTTPS）需要已停止维护的 virtual-media 服务，镜像里没有，网页默认也不显示。上板验证：网页选一个 ISO 点开始，主机里应出现一个 USB 光盘/U 盘；BMC 上 `ls /sys/kernel/config/usb_gadget/`、`ls /dev/nbd0`。
* **U-Boot 启动方式**：固定从本地 SPI 闪存启动（`bootcmd = run bootspi`），不自动走网络；U-Boot 默认网络参数与 Linux 的 eth0 一致（192.168.185.200/24，网关 192.168.185.1，TFTP 服务器 192.168.185.84），只用于手动 TFTP 启动调试和 `run netupdate`。虚拟机与物理主板的区别、环境重置、排查步骤详见第四章 “4. U-Boot 的 TFTP 使用”。
* **时间和 SEL**：BMC 系统时间默认从板上 RTC（NCT3015Y）读取，SEL 时间戳用系统时间。AST2600 内部 RTC 已关闭，NCT3015Y 是 `rtc0`。
* **SEL 记录**：电压、温度（含 CPU_MAX_TEMP / DIMM_MAX_TEMP，含不可恢复级别）、watchdog 超时、BIOS 启动失败（600 秒）、电源按键都会写 SEL。SEL 为 rollover，用标准的 logrotate 实现（`ceb-gnrd-sel-logrotate`，每 5 分钟检查一次，单个文件 15 KiB、保留 1 个旧文件），约保留最新 100 到 200 条，更老的删除；按大小轮转，条数是近似值，记录 ID 由 sel-logger 单独保存，不会重复。
* **SSH / SCP**：BMC 用 dropbear 提供 SSH（22 端口），已带 `openssh-sftp-server` 和 `openssh-scp`，`scp` 新旧协议都可用，例如 `scp -P 2222 file root@127.0.0.1:/tmp/`（QEMU）。
* **SOL**：走 AST2600 的 VUART1（主机看到的是 COM1，I/O 0x3F8，经 eSPI），可双向；obmc-console 用 `ttyVUART0`，BIOS 的串口重定向要选 COM1。UART3 RX 仍保留但不再是 SOL 来源。网页 SOL 可以输入（原来的只读补丁 `0005` 已移除）。
* **风扇控制**：6 个风扇可单独或统一设置（网页下拉框是“全部风扇”和 `SYS_FAN0` 到 `SYS_FAN5`），模式只有“自适应”（最低 30%、最高 100%，固定默认值，没有最低转速滑块）和“固定转速”（20/40/60/80/100%）。页面下方有命令框：上面一个是读取每个风扇转速和模式的命令，下面一个随当前选择实时生成设置命令。风扇控制器（Pid）在 Entity-Manager 里叫 `Fan0 Control` 到 `Fan5 Control`，不能和风扇本身的 `SYS_FAN0` 到 `SYS_FAN5` 同名。
  * **IPMI OEM 命令**（netfn 0x30，只有两条，ipmitool 不用改，KCS 和 LAN 都可用，已加入白名单；由 `ceb-gnrd-ipmi-fan` 库实现，转发给 `ceb-gnrd-fan-settings` 服务）：`ipmitool raw 0x30 0x01` 读取，返回 25 字节：第 0 字节“重启后保留”标志，之后每个风扇 4 字节（模式 0 自适应/1 固定、占空比 %（`0xFF` 表示读不到）、RPM 低字节、RPM 高字节）；`ipmitool raw 0x30 0x02 <风扇 0-5 或 0xFF 全部> <模式> <占空比十六进制> <保留 0/1>` 设置，例如 `ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01` 是全部风扇固定 60% 并保留；需要 Admin 权限。
  * **网页保存的实现**：bmcweb 的 D-Bus REST 在这个版本里不能给方法传参数，Entity-Manager 对 Pid 属性的写入又会“值已改但返回 InvalidArgs”，所以网页每次保存只调用 `ceb-gnrd-fan-settings` 里一个不带参数的方法 `ApplyFan<0..5|All><Adaptive|Fixed20/40/60/80/100><Keep|Forget>`，方法名已包含风扇、模式和是否保留，避免多客户端交错覆盖；服务写 Entity-Manager 后会回读确认。勾选“BMC 重启后保留这些设置”时，设置保存到 `/var/lib/ceb-gnrd/fan-settings.json`，重启和断电重启后恢复，不勾选则 BMC 重启后回到自适应。该功能依赖 bmcweb 的 `dbus-rest`。
* **升级后保留**：普通固件升级不会清读写分区；需要清读写分区的升级会按白名单保存时区、主机名、SSH 主机密钥、网站证书和风扇设置。恢复出厂则全部清除（MAC 不受影响）。

### 4. IPMI

* `mc info`：Device ID 0，Device Revision 1，Product ID 3346（`0x0D12`），Manufacturer ID 6659（`0x1A03`），在 BMC 上的 ipmitool 显示 `CTOPAI` / `CEB-GNR-D`。
* 传感器：已启用 `dynamic-sensors`，电压/温度/风扇/CPU_MAX_TEMP/DIMM_MAX_TEMP 都会出现在 IPMI。CPU_MAX_TEMP 告警阈值 90/98/105 ℃，DIMM_MAX_TEMP 80/85/95 ℃（UNC/UC/UNR，只设上限）；6 个风扇不设告警，没接风扇读 0 RPM 属正常；温度读不到（主机已开机）时风扇 60%（temp-max 发布 70 ℃，两条曲线在 70 ℃ 都是 60%），风扇读到几个都不影响（FailSafePercent=30）。
* 主机侧 IPMI 走 KCS3（见上）；LAN 通道 1 是 eth0（RMCP+ 只绑 eth0），通道 2 是 NC-SI 的 eth1。
* SEL：存放在 `/var/log/ipmi_sel`，`ceb-gnrd-sel-logrotate`（logrotate 按大小轮转）保持 rollover，sel-logger 加了补丁，把“不可恢复”事件也记成 SEL（CPU/DIMM 最高温的 UNR 放在我们自己的接口上，不用 HardShutdown，所以不会触发任何自动关机）；告警灯的四种告警都有 SEL 记录。
* DCMI（`ipmitool dcmi power reading`、`dcmi get_temp_reading`）：**未配置**，`power_reading.json` 的路径为空，`dcmi_sensors.json` 为空数组，命令会报不支持或没有内容。
* 电压阈值：规格表里的上下限（标称 ±15%）按 Critical 级别配置（`lower critical` / `upper critical`），所以 `ipmitool sensor` 的 LC / UC 列能显示；越限时 sel-logger 直接记成 Critical 事件，告警灯随之点亮。CPU/DIMM 最高温度的 UNC / UC / UNR 都能显示：UNR 在我们自己的接口 `com.ctopai.CebGnrd.Threshold.NonRecoverable` 上，ipmid 加了补丁读取它。**BMC 不会因为任何阈值自动关机**：不使用 HardShutdown / SoftShutdown 接口，并且镜像里去掉了会据此关机的 phosphor-fan 的 sensor-monitor。
* FRU 生成：`ipmitool fru gen [文件名]`（默认 `fru.bin`）。会依次提示 Chassis、Board、Product 三个区域的每个字段，每项都显示含义/格式和默认值（Board/Product 名称 `CEB-GNR-D`，Chassis PN `93-39380-A0`、Board PN `91-39380-A0`、Product PN `81-39380-A0`，序列号为生成当天 UTC 日期 `YYMMDD` 加 `0001`，例如 `2610060001`；序号可手动修改，不自动递增），直接回车就用默认值，输入不合法会提示重输，标准输入不是终端时全部用默认值；字段是可打印 ASCII，最长 63 个字符，日期格式 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:MM`（UTC，留空表示未指定），机箱类型填数字（默认 `0x17` 机架式）。生成后用 `ipmitool fru write 0 fru.bin` 写入主板 FRU（EEPROM 1 KiB，生成镜像须不超过 EEPROM 容量），再用 `ipmitool fru print 0` 核对。
* ipmid 启动：`phosphor-ipmi-host` 有一个 drop-in（`10-ceb-gnrd-wait-sensors.conf`），启动前最多等 90 秒，等映射器里的传感器数量连续 8 秒不变。原因是 ipmid 在传感器刚注册、阈值接口还没出来时去读会失败，开机后一分钟内 `ipmitool sensor` 只剩 2 个静态传感器。代价是开机后约一分钟内 `ipmitool` 不可用（QEMU 里已验证开机后传感器完整）。 PCIe 槽位总线 i2c-0 至 i2c-5（本板没有 slot 2 的总线）。

---

## 七、验证清单

### 0. 一键检查脚本 `ceb-gnrd-check`

镜像里自带 `/usr/bin/ceb-gnrd-check`（源文件 `recipes-phosphor/utils/files/ceb-gnrd-check.sh`），在 BMC 里直接运行，逐项输出 PASS / FAIL，覆盖系统服务、传感器和阈值、IPMI 常规命令、风扇 OEM 命令（设置、读回、保留、清除、非法参数）、Redfish 和网页、RTC、MTD 分区等，同时把 journal、dmesg、D-Bus 树等日志打包。预期值按 QEMU 写的（没有风扇、PECI、主机、RTC），只在板上才有意义的项目标为 info，不会失败。

```bash
ceb-gnrd-check                                   # 在 BMC 里运行；开机后等约 1 分钟再跑（ipmid 要等传感器稳定）
scp -P 2222 root@127.0.0.1:/tmp/ceb-gnrd-check.tar.gz .   # 在 Ubuntu 上取回日志包（QEMU）
```

已知结果：QEMU 里除“Manager 固件版本”一项（见第六章 Web 界面“固件版本”）外全部通过；该脚本没有在物理板上运行过。

### 1. 构建后先在 QEMU 里检查

```bash
systemctl --failed --no-pager                 # QEMU 缺少 KCS、eSPI、PECI 等硬件，对应服务失败属预期
journalctl -b -p err --no-pager | tail -40
ip addr show eth0                              # 应有 192.168.185.200
cat /etc/os-release | head                     # VERSION_ID 应为 2.0.0；ipmitool mc info 的 Firmware Revision 应为 2.00
ipmitool mc info                               # Manufacturer Name CTOPAI，Product Name CEB-GNR-D
```

网页逐项点开：菜单里不应再有 SNMP / 清除密钥 / LDAP / 资源管理；风扇页应列出 6 个风扇；SOL 页应能输入；KVM 页应有“全屏”按钮。

### 2. 上板后重点验证（对应端口指南红字项）

| 项目 | 命令 / 方法 |
| :--- | :--- |
| eSPI | `dmesg \| grep -i espi`；`cat /sys/kernel/debug/*espi*/regs`；对照分析仪抓包 |
| PHY | U-Boot：`mdio list`；Linux：`dmesg \| grep -i -E "phy\|mdio"`、`ethtool -S eth0`、`iperf3` |
| PSU | 插 1 个和 2 个模块各验证：`journalctl -u ceb-gnrd-psu-detect`；`ipmitool sdr` 里应有 PSUn_Temp，`ls /sys/class/hwmon/*/temp*_input` 核对 temp2 确实是电源温度 |
| 电源按键 | `journalctl -u ceb-gnrd-power-button-log -f`；`ipmitool sel list \| tail -3` |
| 告警灯 | 电压越限、温度到 UNR、CPU_MAX_TEMP / DIMM_MAX_TEMP 到 Upper Critical、watchdog 超时、BIOS 启动超过 600 秒各验证一次（共用一个灯，阈值告警恢复后清除，BIOS 超时在后续 POST complete 成功后清除，watchdog 超时重启 BMC 才清除；没有其他故障时熄灭）；`busctl get-property xyz.openbmc_project.LED.GroupManager /xyz/openbmc_project/led/groups/enclosure_fault xyz.openbmc_project.Led.Group Asserted` 应随告警翻转，`cat /sys/class/leds/fault/brightness` 对应亮灭 |
| 风扇 | `busctl tree xyz.openbmc_project.EntityManager \| grep -i pid`；`ls /xyz/openbmc_project/control/fanpwm/`；网页保存后查看 `journalctl -u ceb-gnrd-fan-settings`；OEM 命令：`ipmitool raw 0x30 0x01`、`ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01`（再读一次确认），失败时 `journalctl -u phosphor-ipmi-host` |
| KCS | BMC：`ls /dev/ipmi-kcs3`、`journalctl -u phosphor-ipmi-kcs@ipmi-kcs3`；主机侧：`ipmitool -I open mc info` |
| NC-SI | 主机上电后 `ip -br addr show eth1`、`journalctl -t ceb-gnrd-ncsi`（看有没有重试）；主机关机后接口应被关闭 |
| SEL / 时间 | 制造电压和温度越限，`ipmitool sel list` 里应有事件和解除事件；SEL 超过 2100 条后确认最老的被删；断电重启后 `date`、`ipmitool sel time get` 应保持 RTC 的时间 |
| U-Boot | 第一次要 `env default -a; setenv ethaddr ...; saveenv`，确认 `printenv bootcmd` 是 `run bootspi`；`run netupdate` 后 `reset` |
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
| U-Boot 找不到 `.dtb` | 2019.04 需要把 `ast2600-ceb-gnrd.dtb` 登记进 `arch/arm/dts/Makefile`（已放进 `0001-ceb-gnrd-board-device-tree-network-and-environment.patch`） |
| 网页编译 `Unexpected token` | 模板字符串反引号丢失，补丁里的 JS 要逐字核对 |
| `entity-manager: Probe statement failed to parse: True`，电压、风扇、温度等传感器一个都没有 | Entity-Manager 配置里的 `"Probe"` 只认大写的 `"TRUE"` / `"FALSE"`，写成 `"True"` 整份配置会被拒绝；用 `journalctl -b -p err \| grep -i entity` 看 |
| `aspeed-g6-pwm-tach: Failed to create fan -22`，`fansensor: failed to find match for .../fanN_input` | 6.18 的 PWM/TACH 驱动要求风扇子节点写 `tach-ch` 和 `pwms = <&pwm_tach N 40000 0>`，旧写法（`reg`、`aspeed,fan-tach-ch`）会让它失败 |
| `xyz.openbmc_project.LED.GroupManager.service: start operation timed out`，identify 灯不工作 | 这个版本的 LED 管理器只读 `/usr/share/phosphor-led-manager/led-group-config.json`（或 `/etc/phosphor-led-manager/` 下的同名文件），找不到就一直等 Entity-Manager；用 `phosphor-led-manager_%.bbappend` 把板级 `led.json` 装成这个文件名 |
| `ipmitool mc info` 固件版本 `0.00`、网页运行版本 `--`，`xyz.openbmc_project.Software.BMC.Updater` 不存在 | BMC 镜像更新守护进程没有自启（updater 包整体设了 `SYSTEMD_AUTO_ENABLE = "disable"`），它同时提供 BMC 版本对象和固件上传后端；在 bbappend 里为它单独建 `multi-user.target.wants` 软链接 |
| `ModuleNotFoundError: No module named 'xml'` | `python3-dbus-fast` 配方没带 `python3-xml` 等运行依赖，用到它的 Python 服务要在自己的 `RDEPENDS` 里补 |
| `pin L26 already requested by ...mdio` | EVB 设备树默认启用 `mdio0` 至 `mdio3`，只保留用到的 `mdio1`，其余禁用，否则占用 I2C12 的引脚 |
| 风扇设置：`busctl set-property ... Pid OutLimitMin` 报 `Invalid argument`，网页保存失败，`ipmitool raw 0x30 0x02` 返回 `0xCC` | Entity-Manager 写 Pid 属性时值已经改了却返回 InvalidArgs（它自己的日志里没有报错，根因没有深究）；Pid 与 AspeedFan 同名会共用一个 D-Bus 路径，所以把 Pid 改名为 `Fan<n> Control`；`ceb-gnrd-fan-settings` 写完后回读确认，值对了就算成功；网页和 OEM 命令在 QEMU 里都已验证可用 |
| `ipmitool raw 0x30 0x01` 返回 `0xCE`，服务日志有 `can't concat list to bytearray` | dbus-fast 的 `ay` 返回值必须是 `bytes`，不是整数列表 |
| 网页调 D-Bus REST 方法报 `Invalid method arg type`、对属性 PUT 报 `Invalid arg type` | 这个 bmcweb 版本的 D-Bus REST 不能传标量参数；网页只调用不带参数的方法（见第六章“风扇控制”） |
| 开机后约一分钟内 `ipmitool sensor` 只有 2 个传感器，日志有 `Failed to update sensor map for threshold sensor` | ipmid 在传感器的阈值接口出现前去读；`phosphor-ipmi-host` 的 drop-in 让它等传感器数量稳定后再启动 |
| Redfish `FirmwareVersion` 为空、网页 BMC 版本 `--`，但 `busctl` 里版本对象存在 | bmcweb 默认从 `/xyz/openbmc_project/software/bmc/functional` 取版本，经典更新服务发布在 `/xyz/openbmc_project/software/functional`；`bmcweb_%.bbappend` 里设 `-Dredfish-updateservice-use-dbus=disabled`（`strings /usr/bin/bmcweb \| grep -c software/bmc/functional` 非 0 说明用的是新路径） |
| `swampd`：`Must have one stepwise point`，风扇不按温度调速 | Entity-Manager 把整数数组（`[40, 50, ...]`）以 `at` 发布，pid-control 读不到，`Stepwise` 的 `Reading`/`Output` 要写成带小数点的 `40.0` |
| 启动日志里有 `mmc0: Failed to initialize a non-removable card` | EVB 设备树启用了 eMMC/SD；本板没有，U-Boot 和 Linux 设备树里都把 `emmc`、`sdhci` 相关节点禁用 |
| `patch-fuzz` 警告出现在 `phosphor-ipmi-host` | 手写补丁的上下文不对；按真实源码重新生成补丁（`0001` 已重新生成） |
| `os-release.bb: git describe --dirty ... No names found` | openbmc 仓库没有带注释的 tag；`git tag -a v2.0.0 -m "CEB-GNRD 2.0.0"`（必须用 `-a`），固件版本号仍由 `DISTRO_VERSION` 决定（定义在 `meta-ctopai/conf/distro/ctopai-openbmc.conf`，`local.conf` 里必须是 `DISTRO ?= "ctopai-openbmc"`，`./setup ceb-gnrd` 会自动把旧的 `openbmc-phosphor` 改过来；没改的话固件版本会变成 `git describe` 的结果） |
| 告警灯服务日志反复出现 `Unable to read host boot GPIOs: Command '['gpioget', 'gpiochip0', '172']' returned non-zero exit status 1` | 第 172 号线是 `BMC_CPU_PWRGD`，已被 x86-power-control 独占请求，`gpioget` 会报设备忙。告警灯服务改为读 D-Bus 的 `xyz.openbmc_project.State.Chassis` `CurrentPowerState`（x86-power-control 根据这根线发布的状态）；`BMC_BIOS_BOOT_OK` 现在也是 x86-power-control 的 `PostComplete`，同样改读 `OperatingSystemState`，告警灯服务不再直接读任何 GPIO |
| `wrong LCONF_VERSION (has 8, expecting 7)` | 发行版文件 `ctopai-openbmc.conf` 在 `meta-ctopai` 层里，而旧的 `build/ceb-gnrd/conf/bblayers.conf` 只列了 `meta-ceb-gnrd`，没有 `meta-ctopai`；`DISTRO` 找不到发行版文件时 BitBake 不报错（可选包含），`LAYER_CONF_VERSION` 就退回 oe-core 默认的 7（`phosphor-base.inc` 里设的是 8）。把 `meta-ctopai` 加进 `BBLAYERS`（`. setup ceb-gnrd` 会自动补），或在 `bblayers.conf` 里手动加一行 `/home/test/openbmc/meta-ctopai \` |
| `ipmitool sel list` 一直是 "SEL has no entries"，但 journal 里有 `sel-logger ... threshold assert` | rsyslog 没有读 journal：默认只加载 `imuxsock`，拿不到 `MESSAGE_ID`、`IPMI_SEL_*` 字段，`/var/log/ipmi_sel` 就从来没被写入。`rsyslog_%.bbappend` 里要 `PACKAGECONFIG:append = " imjournal"`（Intel 参考平台同样这么做）；开机日志里应有 `imjournal`，没有 `Acquired UNIX socket ... syslog` 之外的输入就说明没生效 |
| `ipmitool sel list` 有记录，但网页 “Event logs” 是空的 | 网页读的是 Redfish 事件日志 `/var/log/redfish`（格式 `<时间> <MessageId>,<参数>`），和 IPMI 的 SEL（`/var/log/ipmi_sel`）是两个文件。需要 rsyslog 有一条规则，把带 `REDFISH_MESSAGE_ID` 的 journal 条目写进去（`rsyslog_%.bbappend` 安装的 `ceb-gnrd-redfish.conf`，Intel 参考平台同样的规则，同样依赖 `imjournal`）。只有 bmcweb 注册表里有的消息 ID 才会显示 |
| `do_rootfs: Group render has never been defined` | 来自 `rootfs-postcommands.bbclass` 的 `systemd_sysusers_check`，核对 `/usr/lib/sysusers.d/*.conf` 声明的组是否都在 `/etc/group`。`render` 组本来由 `udev` 包创建，但 meta-phosphor 的 `systemd_%.bbappend` 有意把 `udev` 从 `USERADD_PACKAGES` 里去掉（为了让 udev 不依赖 `shadow`，能放进 initramfs，BMC 没有 `/dev/dri`），所以这个告警是预期的，无影响，忽略 |
| `systemd: Failed to set watchdog pretimeout_governor to 'panic'` | `aspeed_wdt` 不支持预超时，内核不提供 `pretimeout_governor`（打开 `CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC` 没有用）；`systemd-conf` 里同名的 `40-hardware-watchdog.conf` 覆盖 meta-phosphor 的那个，去掉 `RuntimeWatchdogPreSec` / `RuntimeWatchdogPreGovernor` |

### 3. 修改网页补丁的建议流程

1. 从 GitHub 下载对应版本的网页源码文件，生成改动后的文件。
2. 用工具生成带 3 行上下文的标准补丁（不要手写 hunk 头）。
3. 在构建机上先 `bitbake -c patch webui-vue`，通过后再完整构建。

---

## 九、板卡层实现说明（原 `meta-ceb-gnrd/README.md`）

> 本章是板卡层 `meta-ctopai/meta-ceb-gnrd` 的实现说明（英文，原来的层 README），和第六章互为补充：第六章按功能列出现状，本章说明各项的实现方式、涉及的文件和还需要上板确认的事项。逐个信号的状态见同目录的 `port_guide.xlsx`。除非注明，本章内容没有在物理板上验证过，仍需要板子的事项集中在本章末尾的 “Open items”。
>
> 参考实现：**meta-ibm/meta-sbp1**（Intel 服务器平台）。构建、QEMU 运行、TFTP 加载和验证方法见第三章到第七章。

### Platform features

#### Flash layout and upgrade

* BMC flash: W25Q512JVFIQ, 64 MiB on AST2600 Firmware SPI (FMC).
  `FLASH_SIZE = 65536`, `FLASH_RWFS_OFFSET:flash-65536 = "55296"`.

      u-boot        0x0000000  0xe0000
      u-boot-env    0x00e0000  0x20000
      kernel        0x0100000  9 MiB     (FIT: kernel, device tree, initramfs)
      rofs          0x0a00000  44 MiB    (squashfs)
      rwfs          0x3600000  10 MiB    (jffs2, settings)

  The Linux and U-Boot device trees must keep these offsets; `netupdate` in
  U-Boot (below) uses the same numbers.
* There is a single image bank. The web UI does not show a backup image.
* A firmware update (`*.static.mtd.tar`: image-u-boot, image-kernel,
  image-rofs, image-rwfs) is staged in `/run/initramfs` and written by the
  initramfs update script when the BMC reboots:
  * kernel and rofs are replaced;
  * rwfs is rewritten, and only the files of the OpenBMC whitelist (users and
    passwords, IPMI password, network, DNS, settings) and of
    `recipes-phosphor/initrdscripts/files/ceb-gnrd-whitelist` (time zone, host
    name, SSH host keys, web certificates, fan settings, bmcweb data with the
    web login sessions) are restored, so the web page stays logged in; the SEL
    and event logs are lost;
  * U-Boot is **not** rewritten (`ceb-gnrd-update-skip-u-boot.sh`, a power loss
    while it is written would leave a board that does not boot); create
    `/run/initramfs/update-u-boot` before the reboot to update it on purpose;
  * the U-Boot environment (MAC addresses) is not part of the package.

  A factory reset clears everything in rwfs.

#### U-Boot

* Boot order: `bootcmd` is fixed to `run bootspi`, the FIT image in the local SPI flash; U-Boot never loads the system over the network by itself. TFTP is only used by hand: `tftpboot 0x83000000 fitImage` and `bootm` for kernel debugging (the root file system still comes from the local `rofs`), and by `run netupdate` below.
* Default network settings equal Linux `eth0`: 192.168.185.200/24, gateway
  192.168.185.1, server 192.168.185.84 (set in `aspeed-common.h` by
  `0001-ceb-gnrd-board-device-tree-network-and-environment.patch`, which also
  registers the device tree and adds the board environment to the default one).
* `run netupdate` (variables in `recipes-bsp/u-boot/files/ceb-gnrd-env.h`)
  fetches `image-kernel` and `image-rofs` over TFTP and writes them with
  `sf update` to the kernel and rofs partitions after checking their size. It
  never writes U-Boot, the environment or `rwfs`.
* The environment is stored in flash, so a previously saved environment (for example an older `bootcmd` that tried TFTP first) hides the new defaults: run `env default -a; saveenv` once (and set `ethaddr`, which
  is random otherwise).
* U-Boot uses only the RGMII port. The NC-SI MAC (`&mac2`) is disabled in the
  U-Boot device tree: with a `phy-mode` its probe crashes U-Boot (data abort and
  reset loop), without one it only prints "Invalid PHY interface".
* In QEMU the TFTP server is 192.168.185.1 (QEMU's `tftp=` option) instead of
  192.168.185.84, and the PHY/`mii` behaviour is emulated (RGMII timing and the
  RTL8211FS delays must be checked on the board).

#### BIOS interaction (BIOS 菜单交互)

* **PLDM over MCTP** (`conf/distro/include/pldm.inc`): BIOS attribute tables
  and setup (menu) settings exposed through Redfish `Systems/system/Bios`,
  plus PLDM sensors and PLDM firmware update. Needs PLDM support in the BIOS.
* **biosconfig-manager**: view and modify BIOS setup parameters remotely via
  the BMC (see https://github.com/openbmc/bios-settings-mgr).
* **phosphor-host-postd + phosphor-post-code-manager**: BIOS POST code pipeline
  for I/O port 0x80. The AST2600 LPC snoop node is enabled for port 0x80;
  validate POST capture on hardware. LPC snoop is only a monitor, not the eSPI
  Peripheral I/O-cycle completion path.
* **phosphor-software-manager** with `flash_bios`: host BIOS update through
  the Macronix MX25U51245GMI00 (64 MiB) on AST2600 SPI1 in single-bit mode.
  If the host is on, the updater notifies through its service log and waits up
  to 30 minutes for a stable Off state; it never takes BIOS flash ownership
  while the host is running. It then selects BMC flash ownership with
  GPIOM1/NDCD1 as GPIO before locating the MTD (and retries SPI-NOR probe if
  needed), waits five seconds for the CPLD to place the CPU in S5, and flashes
  the full-chip `host-bios` MTD. Afterward it restores BIOS ownership and
  issues one ForceOff power-button pulse, then requests PowerOn. If the host is
  still On, the normal chassis Off request generates the configured 8-second
  override; if already Off/S5, a guarded board-specific method in
  x86-power-control generates that pulse without taking GPIO ownership away
  from the daemon. Confirm GPIO polarity and verify power sequencing on the
  assembled board.
  Only selected flash regions are written (`flashrom -l <layout> -i <region>`,
  which also skips unchanged blocks); the other regions keep their content.
  The layout is fixed for the board: `/usr/share/ceb-gnrd/bios-layout.txt`
  (descriptor, metadata, pdr, bios, nac1, nac0, reserved; the web page has the
  same table).  The regions come from `bios-regions.txt` in the
  package, which the web firmware page adds from its check boxes; without it
  (curl, Redfish clients) every region except nac0/nac1 is written.  nac0/nac1
  hold the CPU's integrated network controller settings and MAC addresses; the
  web page selects them only after a confirmation dialog.  The image must be
  the full 64 MiB flash image.
  Each step writes a percentage to the update's
  `ActivationProgress` object, bmcweb turns it into the PercentComplete of the
  Redfish update task, and the web firmware page (patch 0013) shows a progress
  bar with the step name; the numbers are listed in `bios-update.sh` and must
  match the table in that patch.
* **phosphor-ipmi-flash**: IPMI in-band firmware update via BLOB protocol
  (host-bios targets enabled when `flash_bios` PACKAGECONFIG is active).
* **Host/chassis state management**: `MACHINE_FEATURES` includes
  `obmc-host-state-mgmt`, `obmc-chassis-state-mgmt`,
  `obmc-phosphor-chassis-mgmt`, `obmc-phosphor-flash-mgmt`. Host and chassis
  state come from `x86-power-control` (`power-config-host0.json`: PowerOk
  `BMC_CPU_PWRGD`, PowerOut `BMC_CPU_POWER_BUTTON`, ResetOut `BMC_CPU_RESET`,
  200 ms power pulse, 8 s force-off, 500 ms reset). Machine uses
  `obmc-bsp-common.inc` (managed server), not `obmc-evb-common.inc`.
* The chassis power button input `BMC_POWER_BUTTON_INPUT` is detect-only: a
  press is written to the SEL and the journal (`ceb-gnrd-power-button-log`). It
  neither starts a power transition nor passes through to the CPU power button
  output.
* What the Redfish side needs from the BIOS (boot progress over IPMI, one-time
  boot device through Get System Boot Options, SEL writes, SMBIOS hand-over for
  system/CPU/memory inventory, PLDM for `Bios`) is not provided by this layer;
  system, processor and memory inventory tables are therefore removed from the
  web UI.

#### eSPI and host IPMI (KCS)

* The board wires AST2600 eSPI to the Xeon 6 host. GPIOW0-W7 are dedicated to
  this connection: `pinctrl_espi_default` covers W0-W5/W7 and the separate
  `pinctrl_espialt_default` covers W6/AD7; both are selected by the eSPI node.
  The Peripheral and Virtual Wire channels are enabled (the host, an Intel PCH,
  always uses Virtual Wire); Flash Access is not used. OOB is not required for
  KCS/IPMI, POST code or the VUART SOL (the VUART is configured by the BMC).
* The pinned `linux-aspeed` revision (`c0538446`) lacks the AST2600 eSPI
  controller driver. The board carries a focused driver
  (`0001-soc-aspeed-add-AST2600-eSPI-peripheral-ready-driver.patch`; its
  Makefile line is part of the same patch) and enables
  `CONFIG_ASPEED_ESPI`. It enables the Peripheral and Virtual Wire channels:
  it asserts Peripheral and Virtual Wire Software Ready and the slave boot
  done / status system events (`ESPI098` bits 20 and 23, which the host
  waits for), resets the block on a host eSPI reset and sets all of that again
  (the wires themselves, GPIO and system events, stay in hardware mode, there
  is no software mode and no Virtual Wire interrupt), counts channel errors/aborts, logs
  state changes (rate limited) and offers a debugfs `regs` dump. Check
  `dmesg | grep -i espi` first if the host cannot reach the BMC.
  `CONFIG_ASPEED_LPC_SIO` does not exist in this kernel and is not added.
* Peripheral I/O cycles are completed by the AST2600 hardware once Peripheral
  Ready is set; `ASPEED_LPC_SNOOP` is only the port 0x80 monitor.
* Host IPMI: ASPEED KCS BMC, IPMI and raw cdev options, `phosphor-ipmi-kcs`
  with its default `ipmi-kcs3` device. The device tree enables `&kcs3` with
  `aspeed,lpc-io-reg = <0xca2>`; the kernel driver does not probe without that
  property. No SerIRQ is configured for KCS: the host polls the status
  register. The BIOS must set its BMC KCS port to 0xCA2.
* GPIOP7 (`BMC_HBLED#`) starts off. A board service enables the kernel LED
  heartbeat trigger once the eSPI Peripheral driver binds and sets `SW_READY`.

#### PECI, temperatures and fan control

* AST2600 PECI0 is enabled for the BMC_CPU_PECI connection (package ball AT29).
  The kernel enables `CONFIG_PECI`, `CONFIG_PECI_CPU`, `CONFIG_PECI_ASPEED`,
  `CONFIG_SENSORS_PECI_CPUTEMP`, `CONFIG_SENSORS_PECI_DIMMTEMP`.  The stock
  `peci-cpu` driver does not know Granite Rapids (Xeon 6, CPUID model 0xAD /
  0xAE), so the kernel patch `0003-peci-add-Granite-Rapids-CPU-and-DIMM-temperature.patch`
  adds it with the Emerald Rapids tables (copied, not verified on the board: check
  `ls /sys/bus/peci/devices/0-30` for `peci_cputemp.*` / `peci_dimmtemp.*` and
  the readings).  IntelCPUSensor is not built (`PACKAGECONFIG:remove`, no `XeonCPU`
  entry in `ceb-gnrd.json`): no per-core or per-DIMM sensor appears in IPMI,
  Redfish or the web page, only the two maxima below.  Only AST2600 I3C3 is
  enabled; DIMM temperature is read over PECI, not I3C.
* `ceb-gnrd-temp-max` (Python, dbus-fast) publishes two sensors,
  `/xyz/openbmc_project/sensors/temperature/CPU_MAX_TEMP` and `DIMM_MAX_TEMP`,
  as the maximum of the temperatures of the kernel `peci_cputemp` (CPU) and
  `peci_dimmtemp` (DIMM) hwmon devices, read from sysfs (DTS, Tcontrol, Tthrottle,
  Tjmax and margin readings are excluded by label).
  Host off: 0. Host on and no reading: 70 degC, which both fan curves map to 60 % (no alarm).
  Upper thresholds only (non-critical / critical / non-recoverable):
  CPU 90 / 98 / 105 degC, DIMM 80 / 85 / 95 degC.  The first two use the Warning
  and Critical threshold interfaces; the non-recoverable one is on a private
  interface (`com.ctopai.CebGnrd.Threshold.NonRecoverable`), never on
  HardShutdown: the BMC must not shut the system down because of a threshold,
  and services such as phosphor-fan's sensor monitor power the system off on a
  HardShutdown alarm (that monitor is also removed from the image).  The service
  emits `ThresholdAsserted` signals, which phosphor-sel-logger turns into SEL
  records; a board patch of ipmid shows the non-recoverable value as UNR. The discovered
  source sensor names are logged (`journalctl -u ceb-gnrd-temp-max`) and need
  checking on the board.
* Fans are driven by `phosphor-pid-control` from the Entity-Manager
  configuration (`ceb-gnrd.json`): six fan PID controllers (Fan0 Control to Fan5 Control, inputs SYS_FAN0-5, outputs
  PWM0-PWM5, limit 30-100 %), one zone (MinThermalOutput 30) and two stepwise
  curves on CPU_MAX_TEMP and DIMM_MAX_TEMP. The curve points are placeholders
  awaiting confirmation. The zone fail-safe is 30 % on purpose: the number of
  fans that can be read must not decide the fan speed; the temperature
  sensors do that (unreadable CPU or DIMM temperature: 60 %). The six fans have no speed alarms and
  an unpopulated header simply reads 0 RPM.  The Pid objects must not share a
  name with the AspeedFan objects (SYS_FAN0-5): both would get one D-Bus path and
  writes to the Pid properties fail.  Stepwise `Reading`/`Output` arrays are
  written with a decimal point (`40.0`) because pid-control cannot read the
  unsigned-integer arrays Entity-Manager publishes for `40`.
* `ceb-gnrd-fan-owner` hands the fans from the CPLD to the BMC
  (GPIOI6 `BMC_FAN_BMC_OVERRIDE_N`) once pid-control is running and all six
  PWM/TACH channels exist, and returns them when pid-control stops.
* `ceb-gnrd-fan-settings` backs the web UI fan page (per-fan or common limits,
  optional persistence across BMC restarts in `/var/lib/ceb-gnrd`); it
  re-applies the stored limits to the Entity-Manager Pid objects every 30 s.
  Adaptive mode uses fixed limits (30 % to 100 %); there is no minimum-speed
  setting.  Entity-Manager answers a write to a Pid property with InvalidArgs
  although the value is changed (root cause not pursued), so the service reads the value
  back and accepts it when it matches.  bmcweb's D-Bus REST cannot pass scalar
  arguments in this version, so the page makes one argument-free call whose
  method name carries the whole request: `ApplyFan<0..5|All><Adaptive|Fixed20..100><Keep|Forget>`.
* The same control is exposed as two IPMI OEM commands, netfn 0x30:
  `0x01` Get (flag byte, then mode/duty/RPM-low/RPM-high for SYS_FAN0..5, 25
  bytes, duty `0xFF` = unknown) and `0x02` Set (fan 0-5 or 0xFF, mode, duty,
  persist; Admin).  They are implemented by the `ceb-gnrd-ipmi-fan` ipmid provider
  (pulled in by `ceb-gnrd-ipmi`) and whitelisted in `ceb-gnrd-ipmi-whitelist.conf`.
  Checked in QEMU with `ceb-gnrd-check` (set, read back, keep, clear, invalid
  fan); not checked on the board.

#### Boot, ipmid start and board self-check

* The AST2600 SD/eMMC controllers are disabled in the U-Boot and Linux device
  trees (the EVB include enables them); the board has neither.
* Hardware watchdog: WDT1 resets the SoC only (`aspeed,reset-type = "soc"`, not
  the whole chip, so GPIOs keep their state; check on the board).  systemd feeds it
  (`RuntimeWatchdogSec=120s`).  `aspeed_wdt` has no pre-timeout, so `systemd-conf`
  installs a `40-hardware-watchdog.conf` with the same name as meta-phosphor's
  (the one in /etc wins) that keeps only `RuntimeWatchdogSec=120s` and drops
  `RuntimeWatchdogPreSec` / `RuntimeWatchdogPreGovernor=panic` (otherwise systemd
  logs "Failed to set watchdog pretimeout_governor" at every boot; clearing them
  with an empty assignment is rejected by systemd).
* A kernel oops becomes a panic (`CONFIG_PANIC_ON_OOPS`) and a panic restarts the
  BMC after 5 s (`CONFIG_PANIC_TIMEOUT=5`).  Magic SysRq is enabled (not from the
  serial BREAK) so that `echo c > /proc/sysrq-trigger` can test this.
* Service recovery uses the standard systemd / OpenBMC mechanisms
  (`ceb-gnrd-health`).  This layer's own fan-settings, temp-max and alert-led
  services get a drop-in with `Restart=always` and a start limit (5 starts in 5
  minutes) and nothing else: systemd runs `OnFailure=` at every failure, also one
  that is followed by an automatic restart (seen on the VM: one SIGKILL of
  temp-max quiesced and rebooted the BMC), so they must not have it.  The object
  mapper, Entity-Manager, bmcweb and ipmid get the same plus
  `OnFailure=obmc-bmc-service-quiesce@0.target`, so the first failure of one of
  them (it is restarted too, but the BMC reboots anyway) makes
  phosphor-state-manager put the BMC into Quiesced; the option
  `auto-reboot-on-bmc-quiesce` (`phosphor-state-manager_%.bbappend`) then reboots
  it.  Upstream puts no limit on these reboots; `ceb-gnrd-quiesce-reboot-limit.sh`
  (ExecCondition of `phosphor-bmc-quiesce-reboot.service`) allows at most 1
  automatic reboot, counted in the read-write flash and cleared 15 minutes after a
  boot by `ceb-gnrd-quiesce-reboot-clear.timer`.  If the fault is still there
  after that reboot the BMC stays Quiesced (a SEL record is written) for manual
  recovery.  The upstream daemons do not ping the systemd watchdog,
  so only crashes are recovered for them (a hang that keeps the process alive is
  not).  This layer's own services are `Type=notify` with `WatchdogSec=` and
  ping from their main loop, so a hang restarts them.
  `ceb-gnrd-wdt-reset-log` writes a SEL record when `bootstatus` shows a
  watchdog reset without the clean-shutdown marker (a `reset` typed in U-Boot is
  also reported once).  Neither has been built or run yet.
* `phosphor-ipmi-host` has a drop-in (`10-ceb-gnrd-wait-sensors.conf`) that waits
  up to 90 s until the number of D-Bus sensors has been stable for 8 s.  Started
  earlier, ipmid read the sensors before their threshold interfaces existed and
  offered only the two static sensors for the first minute.  Cost: `ipmitool`
  is not available for about a minute after boot.
* `ceb-gnrd-boot-progress` (`recipes-phosphor/state`) publishes the host boot
  progress (`xyz.openbmc_project.State.Boot.Progress` on
  `/xyz/openbmc_project/state/host0`) from the port 80 POST codes, because
  nothing upstream derives it and the host does not report it.  The POST code
  ranges (`STAGES` in the script) follow the public AMI Aptio checkpoints and
  Intel MRC; the GNR-D BIOS vendor's POST code list is authoritative.  Shown by
  the IPMI `Boot_Progress` sensor and the web discrete sensor table; Redfish
  `BootProgress` is read by bmcweb from x86-power-control and stays empty.
* `ceb-gnrd-check` (`recipes-phosphor/utils`, installed to `/usr/bin`) runs on
  the BMC, prints PASS/FAIL for services, sensors and thresholds, IPMI commands,
  the fan OEM commands, Redfish, RTC and MTD layout and bundles logs into
  `/tmp/ceb-gnrd-check.tar.gz`.  Its expected values are those of the QEMU run.
  Known FAIL there: Manager `FirmwareVersion` (see the bmcweb note above).
* `bmc-hw-dump` (`recipes-phosphor/utils/files/bmc-hw-dump.sh`, installed to
  `/usr/bin`) is a read-only dump of how the running firmware uses the hardware
  (GPIO, pin mux, I2C, eSPI/KCS/VUART, network, flash, ...).  Copy the script to
  the old vendor firmware and run it there, run `bmc-hw-dump` on this firmware,
  then compare on the PC with `sh bmc-hw-dump.sh compare OLD.tar.gz NEW.tar.gz`.
  `ceb-gnrd-checklist.txt` in the dump lists every ceb-gnrd hardware function
  with the expected and the found value.

#### Alignment with OpenBMC conventions

* x86 platform setup follows the Intel reference platform: `obmc-host-ctl` is not
  a machine feature (its only provider is OpenPOWER's `obmc-op-control-host`) and
  `VIRTUAL-RUNTIME_obmc-discover-system-state` is `x86-power-control`, which also
  applies the power restore policy at BMC boot.  The factory default of the policy
  is AlwaysOn (the host powers on when AC power returns); it is set in
  `phosphor-settings-manager/settings.override.yml`, and a policy already saved in the
  read-write partition (changed in the web UI) is kept until a factory reset.
* Private D-Bus names use the vendor domain: services and interfaces are
  `com.ctopai.CebGnrd.*` (`FanSettings`, `TempMax`, `Threshold.NonRecoverable`).
  The fan settings object path stays `/xyz/openbmc_project/ceb_gnrd/fan_settings`
  because the bmcweb D-Bus REST API only serves object paths under `/xyz` and
  `/org`.
* Changes to upstream sources are patch files, not `sed`: U-Boot
  (`0001-ceb-gnrd-board-device-tree-network-and-environment.patch`), the kernel
  Makefile line (inside the eSPI patch), ipmitool's product name
  (`0002-ipmitool-add-ceb-gnrd-product-name.patch`).  The x86-power-control and
  ipmid patches were regenerated against the pinned sources, so the `patch-fuzz`
  QA downgrade is gone.  The ipmitool manufacturer name (IANA enterprise number
  6659) still comes from a line added to the installed `enterprise-numbers` data
  file in `do_install:append`, because that file is not part of the ipmitool source.
* `DISTRO_VERSION` is defined in the vendor distro `ctopai-openbmc`
  (`meta-ctopai/conf/distro`); `local.conf` must select it (`./setup ceb-gnrd`
  migrates an old `DISTRO ?= "openbmc-phosphor"`).  The board hardware contract is
  installed through `MACHINE_EXTRA_RDEPENDS`, not a machine feature.
* Not changed on purpose: bmcweb keeps `redfish-updateservice-use-dbus=disabled`
  and phosphor-software-manager keeps the classic updater
  (`software-update-dbus-interface` removed, BMC updater enabled by a symlink).
  The default flow replaces `xyz.openbmc_project.Software.BMC.Updater` by
  `Software.Manager` and the BIOS update here (`bios-update.sh`,
  `obmc-flash-host-bios@.service`) is built on the classic flow, so switching
  needs the BIOS update re-done and tested on the board.
* None of this was built or run.
#### RTC and log time

* The NCT3015Y-R is on AST2600 I2C10 (Linux `i2c-9`, address `0x6f`) and is
  bound with the `nuvoton,nct3018y` driver (register compatibility with the
  NCT3015Y is not verified on hardware). The AST2600 internal RTC has no
  battery, so it is disabled in the device tree and the NCT3015Y is `rtc0`.
* The BMC system time, and with it the SEL and journal timestamps, comes from
  the RTC by default: `CONFIG_RTC_HCTOSYS` at boot, with `ceb-gnrd-rtc-sync` as
  a safety net (waits up to 3 s for `/dev/rtc0`, so a machine without an RTC,
  such as QEMU, waits the full 3 s; start timeout 5 s). `CONFIG_RTC_SYSTOHC` writes the time back
  after NTP sync. Keep the RTC in UTC.

#### Board hardware map

The workbook-derived map is installed as
`/usr/share/ceb-gnrd/ceb-gnrd-hardware-contract.yaml`. It records the 16 I2C
buses, the CPU I3C3 management bus, AST2600 ADC pads 0-15, six PWM/TACH fan
channels and the named power, reset and alert GPIOs. Chassis-open detection
uses the AST2600 dedicated CHASI# intrusion input through the intrusion hwmon
latch (`0002-hwmon-add-AST2600-chassis-intrusion-driver.patch`).

* Four NST175H-QSPR temperature sensors on I2C7 (Linux `i2c-6`): inlet `0x48`,
  outlet `0x49`, PCIe `0x4a`, M.2 `0x4b`, measurement only.  They are created by
  Entity-Manager / dbus-sensors (Type `LM75A`), not declared in the device tree
  (declaring them in both places logged `Failed to register i2c client lm75a ...
  (-16)` at every scan).
* ADC: both ADC engines use the 2.5 V internal reference. `D3V0_BAT0` is
  read as built (R542/Q39 not populated, so the 3 V battery saturates the
  input) until the schematic is corrected.
* CRPS power supplies: schematic I2C8 (Linux `i2c-7`), PMBus addresses
  `0x58`/`0x59`/`0x5a`, 0 to 2 modules installed. The device tree declares no
  PMBus nodes: `ceb-gnrd-psu-detect` polls the three addresses every 5 s with a
  STATUS_BYTE read and creates or deletes the pmbus device for each module, so
  empty slots log no probe failures. Entity-Manager/PSUSensor publishes input
  and output voltage and power plus `PSUn_Temp` (pmbus `temp2`). No presence,
  redundancy or threshold alarm is configured.
* CPU PROM/SMBUS_HOST: `BMC_PROM_SCL/SDA` on AST2600 I2C15 (Linux `i2c-14`); no
  EEPROM client is created.
* Board revision: `PCB_VER[2:0]` are sampled as GPIO inputs; see the end of
  this file.

#### BMC network ports

* `eth0`: MAC2 with RTL8211FS-CG on the independent management RJ45, static
  IPv4 `192.168.185.200/24`, gateway `192.168.185.1`, DNS `192.168.185.1`,
  `223.5.5.5`, `223.6.6.6`. RGMII mode `rgmii` (the PHY adds no delay, RXDLY
  strap off), PHY address 2 per the schematic note (the strap resistors read 1;
  confirm on the board), PHY reset RTL8211_SYS_RSTN is driven by the CPLD. The
  RGMII delays still need checking on the board.
* `eth1`: MAC3 NC-SI to the Intel E810 (IPMI LAN channel 2), DHCP. The E810
  has no standby power, so `ceb-gnrd-ncsi` keeps the link down while the host
  is off, raises it when the chassis power state becomes On and, because the
  E810 may not answer immediately, cycles the link every 30 s up to three times
  while there is no carrier. systemd-networkd does not change the
  administrative state of this interface itself (`ActivationPolicy=manual`).

The Linux and U-Boot device trees keep this mapping: phandle `mac1` is
physical MAC2 (RTL8211FS, `mdio1`/`ethphy1`), phandle `mac2` is physical MAC3
(NCSI3, E810); physical MAC1 and MAC4 are disabled. Only these two devices
should appear after flashing the updated image.

#### Alerts, SEL and the system alert LED

* One shared LED, `BMC_SYS_ALERT_LED` (GPIOI5, kernel LED label `fault`),
  shows four alarms (`ceb-gnrd-alert-led`).  It is driven by phosphor-led-manager:
  the service only asserts / de-asserts the standard `enclosure_fault` group
  (`Asserted` property, re-sent every 30 s while alerting) and `led.json` maps
  the group to the `fault` LED.  A voltage threshold alarm and a temperature
  upper non-recoverable (UNR) alarm go out when the alarm clears. CPU_MAX_TEMP
  and DIMM_MAX_TEMP also light the LED at Upper Critical (98 C / 85 C), clearing
  when below the threshold if no other fault remains; a host watchdog timeout and a BIOS boot failure (`BMC_BIOS_BOOT_OK`
  not asserted within 600 s of power good) light the LED. The BIOS boot failure
  clears when POST completes successfully, including after a host reset; only
  the host watchdog timeout stays latched until the BMC is rebooted.
  Any of them lights the LED. The service reads no GPIO itself: the
  host power state comes from `xyz.openbmc_project.State.Chassis`
  `CurrentPowerState` and BIOS boot OK from `OperatingSystemState`
  (`xyz.openbmc_project.State.OperatingSystem`, `/xyz/openbmc_project/state/host0`);
  x86-power-control holds both lines (`PowerOk` `BMC_CPU_PWRGD`, standard
  `PostComplete` `BMC_BIOS_BOOT_OK`, high active) exclusively.  A falling
  `PostComplete` edge while the host is on starts the warm-reset check of its
  state machine and records a soft-reset restart cause; it sends no power pulse.
  Not run on the board.
* All four are written to the SEL: voltages and temperatures by
  phosphor-sel-logger's threshold monitor (a board patch,
  `0001-ceb-gnrd-log-non-recoverable-threshold-events.patch`, makes it handle
  the private NonRecoverable interface as upper/lower non-recoverable), the watchdog by its
  watchdog monitor and the BIOS failure by the alert service itself.
* rsyslog loads `imjournal` (`recipes-extended/rsyslog/rsyslog_%.bbappend`): without
  it rsyslog never sees the `IPMI_SEL_*` journal fields and `/var/log/ipmi_sel`
  stays empty (the SEL then reads "no entries" although sel-logger logs events).
* The web "Event logs" page is the Redfish event log, which is a different file
  from the IPMI SEL: bmcweb reads `/var/log/redfish` (lines `<timestamp>
  <MessageId>,<MessageArgs>`, only message IDs known to its registry), and rsyslog
  writes it from journal entries that carry a `REDFISH_MESSAGE_ID`
  (`ceb-gnrd-redfish.conf`, same rule as the Intel reference platform;
  sel-logger's threshold events and the power-button message have one).  Without
  that rule the page stays empty although `ipmitool sel list` has records.
  `redfish` is rotated by the same logrotate run as the SEL (64k, one old file).
* The SEL is a rollover log kept with the standard logrotate
  (`ceb-gnrd-sel-logrotate`): phosphor-sel-logger reads `/var/log/ipmi_sel*` (all
  rotated files) and keeps the next record ID in a file of its own, so IDs are
  never reused.  A timer runs logrotate every 5 minutes with `size 15k` and
  `rotate 1`, i.e. about the newest 100 to 200 records are kept and older ones
  are deleted (size based, so the count is approximate; a burst of records can
  exceed it for up to 5 minutes).  Whether `/var/log` survives a reboot is not
  checked.
* The web event log is fed from the SEL through the journal records of
  sel-logger.

#### IPMI

* `mc info`: Device ID 0, Device Revision 1, Product ID 3346 (0x0D12),
  Manufacturer ID 6659 (0x1A03), shown as `CTOPAI` / `CEB-GNR-D` by the
  on-BMC ipmitool. The board revision is the fourth AUX firmware revision byte.
  Firmware revision comes from `DISTRO_VERSION`, set in the vendor distro `meta-ctopai/conf/distro/ctopai-openbmc.conf` (`DISTRO = "ctopai-openbmc"` in `local.conf`; 2.0.0; the firmware version starts at 2.0, shown as 2.00 by `ipmitool mc info`).
* Sensors: `dynamic-sensors` and `hybrid-sensors` are enabled, so every D-Bus
  sensor (ADC, temperatures, fans, CPU/DIMM maximum, PSU) is visible through
  IPMI next to the static host-state sensors. In QEMU only the two static
  sensors that have D-Bus objects appear.
* Voltage thresholds (nominal +-15 %) use the Critical level (lower critical / upper critical) so that ipmitool shows them; the Entity-Manager board is named "CEB-GNRD" (Redfish chassis "CEB_GNRD").
* LAN: `phosphor-ipmi-net` serves RMCP+ on `eth0`. SOL, user, channel and
  session commands use the standard phosphor-host-ipmid providers.
* DCMI power reading and temperature reading are not configured
  (`power_reading.json` has no path, `dcmi_sensors.json` is empty), so those
  commands return nothing useful.
* `ipmitool fru gen [file]` (a board patch to ipmitool) interactively builds a FRU image (default `fru.bin`) with chassis, board and product info areas: each prompt shows the format, and the default is already in the input line: edit it or press Enter to keep it. Write it with `ipmitool fru write 0 fru.bin`.  FRU 0 is the board EEPROM (chassis type 0x17 or 0x11 gives FRU ID 0); `ceb-gnrd-fru` writes a default FRU into a blank EEPROM at boot and rescans fru-device after each write.
* SSH is dropbear (port 22); `openssh-sftp-server` and `openssh-scp` are
  installed, so `scp` works with both the SFTP-based and the legacy protocol.

#### Web UI

* Languages: English (`en-US`) and Simplified Chinese (`zh-CN`); the others
  are filtered out, including stale saved selections. `zh-CN.json` is a full
  translation maintained in this layer.
* The web UI is patched at build time (`recipes-phosphor/webui/files`, listed in
  `webui-vue_%.bbappend`): languages (0001-0002), fan control page (0003),
  removal of SNMP, key clear, LDAP and the resource-management power page
  (0004), KVM full screen (0006), BMC-only factory reset
  (0007), inventory limited to system, BMC and chassis (0008), removal of the
  overview power card (0009), no backup image card (0010) and BMC dump only
  (0011), no Virtual TPM / RTAD switches (0012).  The firmware page has no
  backup image card for the BMC and for the BIOS (0010).
* bmcweb is built with `dbus-rest` (fan page), `redfish-dump-log` (dump page;
  the recipe leaves the dump routes out otherwise) and
  `redfish-updateservice-use-dbus=disabled`: with the default the Manager
  `FirmwareVersion` is looked up under `/xyz/openbmc_project/software/bmc/functional`,
  while the classic phosphor-image-updater used here publishes
  `/xyz/openbmc_project/software/functional` (not verified after the change). `phosphor-debug-collector`
  produces the BMC dumps. There is no System dump on this platform.
* Virtual media: only "read image from the browser" is supported
  (bmcweb `/vm/0/0` WebSocket, jsnbd, nbd, USB mass storage through the vHub to
  the host). The external-server (CIFS/HTTPS) mode needs the discontinued
  virtual-media service and is neither built nor shown.
* The BIOS card on the firmware page shows `--` for the running version; BIOS
  version reporting is not implemented.
* The overview "power information" card, power cap and anything that needs
  DCMI power support are removed.

#### VGA display output and KVM

* AST2600 GFX DAC output provides the CPU's VGA display path
  (`CONFIG_DRM_ASPEED_GFX`, `&gfx`, GPIOL6/VGAHS and GPIOL7/VGAVS). DDC pins are
  fixed-function.
* The separate `CONFIG_VIDEO_ASPEED` / `&video` path (reserved memory
  `video_engine_memory`) captures host video for KVM; the image has
  `obmc-ikvm` and the bmcweb KVM endpoint. AST2600 USB2A D+/D- goes to host
  VL805 USB port 4: the vHub runs in device mode (`pinctrl_usb2ad_default`),
  EHCI host mode is disabled and configfs HID provides the keyboard and mouse.

#### Host serial-over-LAN

* SOL uses the AST2600 VUART1: the host sees it as COM1 (I/O `0x3F8`) over the
  eSPI Peripheral channel, so it is bidirectional (`&vuart1` in the device tree,
  `CONFIG_SERIAL_8250_ASPEED_VUART`). `obmc-console` uses `ttyVUART0` (symlink
  from `udev-aspeed-vuart`, VUART1 at `0x1E787000`) as `OBMC_CONSOLE_HOST_TTY`
  with `server.ttyVUART0.conf` (default socket name so bmcweb and IPMI SOL
  connect). The BIOS serial redirection must be set to COM1.
* Why VUART: the BIOS detected the AST2600 SuperIO, routed COM1 to eSPI and
  polled the line status register `0x3FD` forever; with no working COM1 behind
  it the register read `00` ("transmitter not empty") and the BIOS hung. A running
  VUART answers that register. Something must read the VUART data (obmc-console
  does), or its buffer fills, the register goes back to "not empty" and the BIOS
  can hang again.
* UART3 RX (`GPIOL5/RXD3`, receive-only) stays muxed but is no longer the SOL
  source. The web SOL page is the stock one (typing is allowed); the old read-only
  patch `0005` was removed.
* The AST2600 SuperIO (I/O `0x2E/0x2F`) is left enabled: the BIOS finds it and
  routes COM1 to the VUART. (`SCU510[3]` would disable it, but only a power-on
  reset clears that bit and the BIOS may then not use COM1 at all.)
* UART5 (`ttyS4`, 115200 baud, balls C8/D8) is the local BMC debug console;
  U-Boot and Linux use it.

#### FRU EEPROM access

* **fru-device** (entity-manager) probes I2C for FRU EEPROMs and publishes
  them on D-Bus.
* **phosphor-ipmi-fru** is wired to the FM24C08D on schematic I2C11 (Linux
  `i2c-10`), address blocks `0x50`-`0x53`, 1 KiB with 16-byte pages. The
  schematic shows a pulldown on `BMC_FRU_WP` (package ball D21, GPIOG6), so
  writes are enabled by default.
* `ceb-gnrd-yaml-config.bb` provides the FRU YAML mapping files
  (`IPMI_FRU_YAML` / `IPMI_FRU_PROP_YAML`); the entity ID and instance are 0.

### Open items

Everything here needs a board (or is waiting for your decision):

* eSPI peripheral channel bring-up and the BIOS KCS port (0xCA2).
* PHY address 2, RGMII delays and U-Boot/Linux network on the real board.
* NC-SI link timing after host power-on (retry interval and count are guesses).
* PSU STATUS_BYTE probing, `temp2` as the PSU temperature, PSU sensor naming.
* The PECI hwmon labels and values of the CPU and DIMM temperatures (read by
  `ceb-gnrd-temp-max`, which logs them) and the fan PWM object names.
* Fan curve temperatures (placeholders), the IANA manufacturer ID (0x1A03 as
  given), firmware version rule.
* Real-hardware checks of SEL records for each alarm, SEL rollover, the RTC
  as time source, SOL output and KVM.
* BIOS version reporting (sbp1's coreboot-based `bios-version` does not apply
  to a UEFI BIOS), SMBIOS-based inventory and DCMI are not implemented.
* `D3V0_BAT0` scaling once R542/Q39 are populated.

### Board revision in IPMI

The three `PCB_VER[2:0]` strap inputs are sampled as GPIO inputs. Their raw
logic levels encode the board revision as `(PCB_VER2 << 2) | (PCB_VER1 << 1) |
PCB_VER0`, producing a value from 0 to 7. `ipmitool mc info` reports this value
in the fourth (last) byte of the AUX Firmware Revision field. The first three
AUX bytes remain unchanged. `CFG_VER0` is a separate configuration strap, and
`CFG_VER1` is reserved; neither is included in the PCB revision.

The AST2600 is an ARM, service management SOC made by ASPEED. More information
about the AST2600 can be found
[here](http://aspeedtech.com/server_ast2600/).
