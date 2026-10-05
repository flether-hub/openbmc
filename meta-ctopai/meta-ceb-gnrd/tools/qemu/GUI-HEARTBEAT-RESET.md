# GUI 心跳与主机复位（2026-10-06）

- 读取 GPIOP7 / offset 127 / BMC_HBLED_N：真实 BMC heartbeat 输出，低有效。
  Tk 和 Web 连接图展示电平/方向/边沿计数，事件日志记录采样到的变化。
  输入未驱动时按板端高电平处理；不从模拟器伪造心跳，不代表全部固件服务健康。
  50ms 最佳努力采样可能漏掉短脉冲。
- Tk Tab 缩短标题、减少左右 padding，原有功能保留。
- 主机控制页新增板端 Reset 按钮，对应 reset 命令和 QOM press-reset-button。
  0023 补丁只重新启动主机合成 POST，保持 PWRGD，不改变 BMC GPIO、不重启 BMC。
  仅 POST/运行状态允许；关机或关机过程中拒绝。不是完整 x86 CPU 硬件复位模型。
- Tk/Web/Python 修改同步后需要重启面板；原生 Reset 接口需要重建 QEMU。
  未编译或运行测试，由用户验证真实心跳输出、布局和 Reset 行为。

固件代码本次未修改。电源恢复策略和虚拟媒体故障仍是独立未完成任务。
