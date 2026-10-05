# 风扇接管就绪扫描修复（2026-10-05）

用户运行证据：FanCtrl zone0 存在，aspeed_tach 的 fan1_input..fan6_input
以及 pwm-fan0..5 的 pwm1 都存在，但 owner 日志一直报告找不到 fan1_input。

根因：ceb-gnrd-fan-owner.sh 在拆分 gpiofind 输出前 set -f，之后未恢复
pathname expansion。两处 hwmon* 扫描因此使用字面路径，所有目录都被跳过。
这是 BMC 固件脚本缺陷，真实板卡同样受影响，不属于模拟器 GPIO 模型问题。

修复：在 set -- $location 后立即 set +f。保留 zone、六路 PWM/TACH、GPIO
持有及复位容忍位检查；不跳过保护条件，不改变接管极性。

尚未构建或运行验证。更新固件后由用户确认服务日志出现 BMC owns the fans
且 GPIOI6 为输出高电平。虚拟媒体及电源恢复策略是独立待处理问题。
