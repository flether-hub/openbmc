# QEMU 启动断言修复（2026-10-05）

用户运行新版 QEMU 时，qdev.c 的 qdev_assert_realized_properly_cb 报告
`Assertion dev->realized failed`。0018 替换 VUART 的 realize/map，但仍创建旧
SerialMM 子设备，导致设备树中留下未 realized 的节点。

0022-aspeed-remove-unrealized-legacy-vuart.patch 删除该遗留子设备；eSPI
Peripheral 模型继续提供 VUART。修复位于模拟器，未修改 BMC 固件。
补丁已加入 qemu-system-native recipe，独立 build-qemu.sh 自动收集。

补丁对本地 post-0018 源码的应用检查通过；未构建、未运行验证。
更新代码并重建 QEMU 后由用户确认启动结果。panel 的 ConnectionResetError
是 QEMU 退出后的后果；旧 PSU 警告不是本次启动断言的直接证据。
