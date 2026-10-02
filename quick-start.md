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
| SD / eMMC | 本板没有，U-Boot 和 Linux 设备树都把 emmc、sdhci 相关节点设为 disabled，开机日志里不再有 mmc0: Failed to initialize a non-removable card |
| 硬件看门狗 | AST2600 WDT1 由 systemd 喂狗（RuntimeWatchdogSec=120s）；内核打开了预超时调节器（CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC），用来消除 Failed to set watchdog pretimeout_governor 提示，不改变看门狗复位行为 ⚠️（若该驱动不支持预超时，提示仍会存在，属无害） |

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
* **已移除**（无后台支持）：转储页的“System dump”选项（只保留 BMC dump）、固件页 BMC 和 BIOS 两处的“备份镜像”卡片以及“切换为运行”（BMC 和 BIOS 都只有一个镜像区）、概览页“电源信息”卡片（功耗读数和功率上限依赖 DCMI 电源支持，本板不提供）、SNMP Alerts、清除密钥、LDAP、策略页的“虚拟 TPM”和“RTAD”开关、资源管理/电源、“仅重置服务器选项”、清单页的 DIMM/风扇/电源/处理器/组件表。
* **转储**：只有 BMC dump（`phosphor-debug-collector`）；转储页走 bmcweb 的 Redfish Dump 服务，需要编译选项 `redfish-dump-log`（已在 `bmcweb_%.bbappend` 里启用，缺了这个选项转储页没有后端）。⚠️ 在 QEMU 里点“开始转储”要约 30 秒才完成，期间再点会报“Another user initiated dump in progress”；转储完成后条目没有出现在列表里的问题还没有查清。
* **固件版本**：bmcweb 默认（`redfish-updateservice-use-dbus=enabled`）到 `/xyz/openbmc_project/software/bmc/functional` 找 BMC 版本，而这里用的经典 `phosphor-image-updater` 发布在 `/xyz/openbmc_project/software/functional`，结果 Redfish 的 `FirmwareVersion` 为空、网页 BMC 卡片显示 `--`；`bmcweb_%.bbappend` 里已把该选项设为 `disabled`（同时固件上传走 `/tmp/images`，和经典更新服务一致）⚠️ 没有验证。`journalctl` 里的 `mapperx: Found invalid association` 是 BMC 版本对象的 `inventory` 关联目标路径为空（找不到 BMC 清单对象），只是告警。网页只提供“从浏览器读取镜像文件”（走 bmcweb 的 /vm/0/0 WebSocket → jsnbd → nbd → USB mass storage → 主机 VL805 USB 口）；“从外部服务器读取镜像文件”（CIFS/HTTPS）需要已停止维护的 virtual-media 服务，镜像里没有，网页默认也不显示。上板验证：网页选一个 ISO 点开始，主机里应出现一个 USB 光盘/U 盘；BMC 上 `ls /sys/kernel/config/usb_gadget/`、`ls /dev/nbd0`。
* **U-Boot 启动方式**：固定从本地 SPI 闪存启动（`bootcmd = run bootspi`），不自动走网络；U-Boot 默认网络参数与 Linux 的 eth0 一致（192.168.185.200/24，网关 192.168.185.1，TFTP 服务器 192.168.185.84），只用于手动 TFTP 启动调试和 `run netupdate`。虚拟机与物理主板的区别、环境重置、排查步骤详见第四章 “4. U-Boot 的 TFTP 使用”。
* **时间和 SEL**：BMC 系统时间默认从板上 RTC（NCT3015Y）读取，SEL 时间戳用系统时间。AST2600 内部 RTC 已关闭，NCT3015Y 是 `rtc0`。
* **SEL 记录**：电压、温度（含 CPU_MAX_TEMP / DIMM_MAX_TEMP，含不可恢复级别）、watchdog 超时、BIOS 启动失败（600 秒）、电源按键都会写 SEL。SEL 为 rollover：约保留最新 2000 条，满了自动丢弃最老的。
* **SSH / SCP**：BMC 用 dropbear 提供 SSH（22 端口），已带 `openssh-sftp-server` 和 `openssh-scp`，`scp` 新旧协议都可用，例如 `scp -P 2222 file root@127.0.0.1:/tmp/`（QEMU）。
* **SOL**：硬件上只能接收（CPU 串口输出接 BMC UART3 的 RX，TXD3 不接管脚），网页、SSH、IPMI 的 SOL 都不能向主机输入；网页提示为只读模式，终端禁用输入。
* **风扇控制**：6 个风扇可单独或统一设置（网页下拉框是“全部风扇”和 `SYS_FAN0` 到 `SYS_FAN5`），模式只有“自适应”（最低 30%、最高 100%，固定默认值，没有最低转速滑块）和“固定转速”（20/40/60/80/100%）。页面下方有命令框：上面一个是读取每个风扇转速和模式的命令，下面一个随当前选择实时生成设置命令。风扇控制器（Pid）在 Entity-Manager 里叫 `Fan0 Control` 到 `Fan5 Control`，不能和风扇本身的 `SYS_FAN0` 到 `SYS_FAN5` 同名。
  * **IPMI OEM 命令**（netfn 0x30，只有两条，ipmitool 不用改，KCS 和 LAN 都可用，已加入白名单；由 `ceb-gnrd-ipmi-fan` 库实现，转发给 `ceb-gnrd-fan-settings` 服务）：`ipmitool raw 0x30 0x01` 读取，返回 25 字节：第 0 字节“重启后保留”标志，之后每个风扇 4 字节（模式 0 自适应/1 固定、占空比 %（`0xFF` 表示读不到）、RPM 低字节、RPM 高字节）；`ipmitool raw 0x30 0x02 <风扇 0-5 或 0xFF 全部> <模式> <占空比十六进制> <保留 0/1>` 设置，例如 `ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01` 是全部风扇固定 60% 并保留；需要 Admin 权限。
  * **网页保存的实现**：bmcweb 的 D-Bus REST 在这个版本里不能给方法传参数，Entity-Manager 对 Pid 属性的写入又会“值已改但返回 InvalidArgs”，所以网页分三次调用 `ceb-gnrd-fan-settings` 里不带参数的方法：`SelectAll` 或 `SelectFan0` 到 `SelectFan5` 选风扇，再 `SetAdaptive` 或 `SetFixed20/40/60/80/100`，最后 `KeepSettings` 或 `ForgetSettings` 决定是否保留；服务写 Entity-Manager 后会回读确认。勾选“BMC 重启后保留这些设置”时，设置保存到 `/var/lib/ceb-gnrd/fan-settings.json`，重启和断电重启后恢复，不勾选则 BMC 重启后回到自适应。该功能依赖 bmcweb 的 `dbus-rest`。
* **升级后保留**：普通固件升级不会清读写分区；需要清读写分区的升级会按白名单保存时区、主机名、SSH 主机密钥、网站证书和风扇设置。恢复出厂则全部清除（MAC 不受影响）。

### 4. IPMI

* `mc info`：Device ID 32，Device Revision 2，Product ID 3346（`0x0D12`），Manufacturer ID 6659（`0x1A03`），在 BMC 上的 ipmitool 显示 `CTOPAI` / `CEB-GNR-D`。
* 传感器：已启用 `dynamic-sensors`，电压/温度/风扇/CPU_MAX_TEMP/DIMM_MAX_TEMP 都会出现在 IPMI。CPU_MAX_TEMP 告警阈值 90/98/105 ℃，DIMM_MAX_TEMP 80/85/95 ℃（UNC/UC/UNR，只设上限）；6 个风扇不设告警，没接风扇读 0 RPM 属正常；温度读不到（主机已开机）时风扇 60%（temp-max 发布 70 ℃，两条曲线在 70 ℃ 都是 60%），风扇读到几个都不影响（FailSafePercent=30）。
* 主机侧 IPMI 走 KCS3（见上）；LAN 通道 1 是 eth0（RMCP+ 只绑 eth0），通道 2 是 NC-SI 的 eth1。
* SEL：存放在 `/var/log/ipmi_sel`，`ceb-gnrd-sel-rollover` 保持 rollover，sel-logger 加了补丁，把“不可恢复”事件也记成 SEL（CPU/DIMM 最高温的 UNR 放在我们自己的接口上，不用 HardShutdown，所以不会触发任何自动关机）；告警灯的四种告警都有 SEL 记录。
* DCMI（`ipmitool dcmi power reading`、`dcmi get_temp_reading`）：**未配置**，`power_reading.json` 的路径为空，`dcmi_sensors.json` 为空数组，命令会报不支持或没有内容。
* 电压阈值：规格表里的上下限（标称 ±15%）按 Critical 级别配置（`lower critical` / `upper critical`），所以 `ipmitool sensor` 的 LC / UC 列能显示；越限时 sel-logger 直接记成 Critical 事件，告警灯随之点亮。CPU/DIMM 最高温度的 UNC / UC / UNR 都能显示：UNR 在我们自己的接口 `xyz.openbmc_project.CebGnrd.Threshold.NonRecoverable` 上，ipmid 加了补丁读取它。**BMC 不会因为任何阈值自动关机**：不使用 HardShutdown / SoftShutdown 接口，并且镜像里去掉了会据此关机的 phosphor-fan 的 sensor-monitor。
* FRU 生成：`ipmitool fru gen [文件名]`（默认 `fru.bin`）。会依次提示 Chassis、Board、Product 三个区域的每个字段，每项都显示含义/格式和占位默认值（`CHASSIS_PART_NUMBER`、`PRODUCT_NAME` 等），直接回车就用默认值，输入不合法会提示重输，标准输入不是终端时全部用默认值；字段是可打印 ASCII，最长 63 个字符，日期格式 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:MM`（UTC，留空表示未指定），机箱类型填数字（默认 `0x17` 机架式）。生成后用 `ipmitool fru write 0 fru.bin` 写入主板 FRU（EEPROM 1 KiB，生成的镜像约 280 字节），再用 `ipmitool fru print 0` 核对。
* ipmid 启动：`phosphor-ipmi-host` 有一个 drop-in（`10-ceb-gnrd-wait-sensors.conf`），启动前最多等 90 秒，等映射器里的传感器数量连续 8 秒不变。原因是 ipmid 在传感器刚注册、阈值接口还没出来时去读会失败，开机后一分钟内 `ipmitool sensor` 只剩 2 个静态传感器。代价是开机后约一分钟内 `ipmitool` 不可用。 PCIe 槽位总线 i2c-0 至 i2c-5（本板没有 slot 2 的总线）。

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

网页逐项点开：菜单里不应再有 SNMP / 清除密钥 / LDAP / 资源管理；风扇页应列出 6 个风扇；SOL 页应有只读提示；KVM 页应有“全屏”按钮。

### 2. 上板后重点验证（对应端口指南红字项）

| 项目 | 命令 / 方法 |
| :--- | :--- |
| eSPI | `dmesg \| grep -i espi`；`cat /sys/kernel/debug/*espi*/regs`；对照分析仪抓包 |
| PHY | U-Boot：`mdio list`；Linux：`dmesg \| grep -i -E "phy\|mdio"`、`ethtool -S eth0`、`iperf3` |
| PSU | 插 1 个和 2 个模块各验证：`journalctl -u ceb-gnrd-psu-detect`；`ipmitool sdr` 里应有 PSUn_Temp，`ls /sys/class/hwmon/*/temp*_input` 核对 temp2 确实是电源温度 |
| 电源按键 | `journalctl -u ceb-gnrd-power-button-log -f`；`ipmitool sel list \| tail -3` |
| 告警灯 | 电压越限、温度超 Upper Critical、watchdog 超时、BIOS 启动超过 600 秒各验证一次（四种共用一个灯，前两种恢复后灭，后两种重启 BMC 才灭） |
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
| U-Boot 找不到 `.dtb` | 2019.04 需要把 `ast2600-ceb-gnrd.dtb` 登记进 `arch/arm/dts/Makefile`（bbappend 里已处理） |
| 网页编译 `Unexpected token` | 模板字符串反引号丢失，补丁里的 JS 要逐字核对 |
| `entity-manager: Probe statement failed to parse: True`，电压、风扇、温度等传感器一个都没有 | Entity-Manager 配置里的 `"Probe"` 只认大写的 `"TRUE"` / `"FALSE"`，写成 `"True"` 整份配置会被拒绝；用 `journalctl -b -p err \| grep -i entity` 看 |
| `aspeed-g6-pwm-tach: Failed to create fan -22`，`fansensor: failed to find match for .../fanN_input` | 6.18 的 PWM/TACH 驱动要求风扇子节点写 `tach-ch` 和 `pwms = <&pwm_tach N 40000 0>`，旧写法（`reg`、`aspeed,fan-tach-ch`）会让它失败 |
| `xyz.openbmc_project.LED.GroupManager.service: start operation timed out`，identify 灯不工作 | 这个版本的 LED 管理器只读 `/usr/share/phosphor-led-manager/led-group-config.json`（或 `/etc/phosphor-led-manager/` 下的同名文件），找不到就一直等 Entity-Manager；用 `phosphor-led-manager_%.bbappend` 把板级 `led.json` 装成这个文件名 |
| `ipmitool mc info` 固件版本 `0.00`、网页运行版本 `--`，`xyz.openbmc_project.Software.BMC.Updater` 不存在 | BMC 镜像更新守护进程没有自启（updater 包整体设了 `SYSTEMD_AUTO_ENABLE = "disable"`），它同时提供 BMC 版本对象和固件上传后端；在 bbappend 里为它单独建 `multi-user.target.wants` 软链接 |
| `ModuleNotFoundError: No module named 'xml'` | `python3-dbus-fast` 配方没带 `python3-xml` 等运行依赖，用到它的 Python 服务要在自己的 `RDEPENDS` 里补 |
| `pin L26 already requested by ...mdio` | EVB 设备树默认启用 `mdio0` 至 `mdio3`，只保留用到的 `mdio1`，其余禁用，否则占用 I2C12 的引脚 |
| 风扇设置：`busctl set-property ... Pid OutLimitMin` 报 `Invalid argument`，网页保存失败，`ipmitool raw 0x30 0x02` 返回 `0xCC` | Entity-Manager 写 Pid 属性时值已经改了却返回 InvalidArgs（原因没有查清，日志里没有它的报错）；Pid 与 AspeedFan 同名会共用一个 D-Bus 路径，所以把 Pid 改名为 `Fan<n> Control`；`ceb-gnrd-fan-settings` 写完后回读确认，值对了就算成功 |
| `ipmitool raw 0x30 0x01` 返回 `0xCE`，服务日志有 `can't concat list to bytearray` | dbus-fast 的 `ay` 返回值必须是 `bytes`，不是整数列表 |
| 网页调 D-Bus REST 方法报 `Invalid method arg type`、对属性 PUT 报 `Invalid arg type` | 这个 bmcweb 版本的 D-Bus REST 不能传标量参数；网页只调用不带参数的方法（见第六章“风扇控制”） |
| 开机后约一分钟内 `ipmitool sensor` 只有 2 个传感器，日志有 `Failed to update sensor map for threshold sensor` | ipmid 在传感器的阈值接口出现前去读；`phosphor-ipmi-host` 的 drop-in 让它等传感器数量稳定后再启动 |
| Redfish `FirmwareVersion` 为空、网页 BMC 版本 `--`，但 `busctl` 里版本对象存在 | bmcweb 默认从 `/xyz/openbmc_project/software/bmc/functional` 取版本，经典更新服务发布在 `/xyz/openbmc_project/software/functional`；`bmcweb_%.bbappend` 里设 `-Dredfish-updateservice-use-dbus=disabled`（`strings /usr/bin/bmcweb \| grep -c software/bmc/functional` 非 0 说明用的是新路径） |
| `swampd`：`Must have one stepwise point`，风扇不按温度调速 | Entity-Manager 把整数数组（`[40, 50, ...]`）以 `at` 发布，pid-control 读不到，`Stepwise` 的 `Reading`/`Output` 要写成带小数点的 `40.0` |
| 启动日志里有 `mmc0: Failed to initialize a non-removable card` | EVB 设备树启用了 eMMC/SD；本板没有，U-Boot 和 Linux 设备树里都把 `emmc`、`sdhci` 相关节点禁用 |
| `patch-fuzz` 警告出现在 `phosphor-ipmi-host` | 手写补丁的上下文不对；按真实源码重新生成补丁（`0001` 已重新生成） |
| `os-release.bb: git describe --dirty ... No names found` | openbmc 仓库没有带注释的 tag；`git tag -a v2.0.0 -m "CEB-GNRD 2.0.0"`（必须用 `-a`），固件版本号仍由 `DISTRO_VERSION` 决定 |
| `do_rootfs: Group render has never been defined` | 某个包的文件属组是 `render`，镜像里没有这个组；无害，忽略 |
| `systemd: Failed to set watchdog pretimeout_governor to 'panic'` | 内核没有预超时调节器；已打开 `CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC`，若驱动不支持预超时仍会提示，无害 |

### 3. 修改网页补丁的建议流程

1. 从 GitHub 下载对应版本的网页源码文件，生成改动后的文件。
2. 用工具生成带 3 行上下文的标准补丁（不要手写 hunk 头）。
3. 在构建机上先 `bitbake -c patch webui-vue`，通过后再完整构建。
