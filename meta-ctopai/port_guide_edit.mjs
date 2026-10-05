import fs from "node:fs/promises";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const path = "D:/openbmc/port_guide.xlsx";
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(path));
const sheet = workbook.worksheets.getItem("端口映射");
const rows = sheet.getRange("A1:J136").values;
const rowByKey = new Map(rows.map((row, index) => [row[1], index + 1]));

const updates = {
  BMC_SYS_ALERT_LED: [
    "告警灯高有效：电压 sensor 越限时点亮，电压告警解除后熄灭；BMC watchdog timeout 或 BIOS 启动 300 秒超时失败时锁存点亮，需重启解除。",
    "GPIOI5 作为 gpio-led；ceb-gnrd-alert-led 服务监听 sensor/Watchdog/BIOS boot 状态并控制输出。",
    "策略及 GPIO 服务已配置；目标机验证告警置位、解除和锁存行为。"
  ],
  "BMC_HBLED_N / HEARTBEAT": [
    "BMC 启动后，在 AST2600 eSPI Peripheral 驱动绑定并完成 SW_READY 初始化时启动周期心跳；不等待 BIOS/Host 实际流量。",
    "gpio-led 初始 off；eSPI driver-ready 门控服务在 SW_READY 后设置 heartbeat trigger。",
    "启动门控已配置；验证 SW_READY 条件、心跳波形及 CPLD 输入极性。"
  ],
  BMC_POWER_BUTTON_INPUT: [
    "物理按键低有效；x86-power-control 处理按钮事件，记录 PowerButtonPressed 事件，并将输入脉冲直通 CPU power-button 输出。",
    "PowerButton GPIO 输入配置在 x86-power-control；button-passthrough 编译选项启用。",
    "事件处理和直通已配置；目标机验证按键电平、事件日志及脉冲。"
  ],
  BMC_BIOS_BOOT_OK: [
    "GPIO 高表示 BIOS boot OK；成功时不做动作。Host PWRGD 后 300 秒未拉高则锁存 BIOS boot timeout 并点亮 SYS_ALERT_LED。",
    "ceb-gnrd-alert-led 服务监控 GPIOM7 和 CPU PWRGD；成功仅停止当前启动周期超时计时，失败锁存告警。",
    "成功无动作、超时点灯及 PWRGD 低电平重新布防已配置；目标机验证 300 秒计时和复位条件。"
  ],
  BMC_UID_BUTTON_N: [
    "低有效 UID button；物理按键、IPMI Chassis Identify 和 Web Identify 共用 enclosure_identify LED group。",
    "gpio button signals / handler 将 ID_BUTTON 映射到 identify LED group；GPIOV1 由 gpio-led-manager 控制。",
    "按键/IPMI/Web 联动已配置；目标机验证按键行为及 identify timeout/熄灭。"
  ],
  BMC_UID_LED: [
    "高电平点亮；物理 UID 按键、IPMI Chassis Identify 和 Web Identify 共用控制此 LED。",
    "gpio-leds 注册 identify LED，phosphor-led-manager 管理 enclosure_identify group。",
    "控制路径已配置；验证硬件高有效极性和 Web/IPMI 实际动作。"
  ],
  BMC_CPU_POWER_BUTTON: [
    "BMC chassis/host power 请求及 Web/KVM 相关主机电源操作通过标准 Host/Chassis D-Bus 状态接口触发低有效脉冲；物理电源按键按原输入脉宽直通。",
    "x86-power-control PowerOut：普通按键 200 ms、强制关机 15 s；PowerOk 监测 BMC_CPU_PWRGD；button-passthrough 已启用。",
    "板级配置已完成；目标机验证 IPMI chassis control、Web/KVM 电源操作、物理按键及 PWRGD 状态反馈。"
  ],
  BMC_CPU_RESET: [
    "Host reset/reboot 请求通过标准 Host/Chassis 控制接口输出低有效复位脉冲；供 IPMI chassis reset 和 Web/KVM 主机重启操作使用。",
    "x86-power-control ResetOut；默认 ResetPulseMs=500，chassis-system-reset 功能已启用。",
    "板级配置已完成；目标机验证 IPMI reset、Web/KVM reset 和 500 ms 脉冲。"
  ],
  BMC_CPU_PWRGD: [
    "CPU/CPLD 提供的高有效主机电源状态反馈；用于 x86-power-control 更新 Host/Chassis 状态及电源时序。",
    "x86-power-control PowerOk 输入，active high；不是 GPIO 输出。",
    "输入已配置；验证上电/掉电边沿和状态机反馈。"
  ],
  BMC_FRU_WP: [
    "FM24C08D FRU 写保护；GPIOG6 高有效保护，低电平允许写入，板级下拉使默认状态可写。",
    "GPIOG6_TXD9_SD2CD#_SALT15 / gpio0 offset 54；at24 节点配置 wp-gpios，由 NVMEM 在写周期控制 WP。",
    "GPIO line name 与 NVMEM WP mapping 已配置；目标机验证 FRU 写保护/写入及引脚电平。"
  ]
};

for (const [key, values] of Object.entries(updates)) {
  const row = rowByKey.get(key);
  if (!row) throw new Error(`Missing guide row: ${key}`);
  sheet.getRange(`G${row}:I${row}`).values = [values];
}

for (const row of rows) {
  if (typeof row[1] === "string" && /^TACH[0-5] \/ SYS_FAN[0-5]_TACH$/.test(row[1])) {
    const index = row[1].match(/TACH([0-5])/)[1];
    const r = rowByKey.get(row[1]);
    sheet.getRange(`G${r}:I${r}`).values = [[
      `输入转速遥测。机箱实际安装风扇数量不固定；0 RPM 或异常转速不代表故障，不记录日志、不生成 SEL/告警，也不触发风扇存在状态变化。`,
      `AST2600 pwm_tach fan@${index} 提供 RPM 读数；未配置 TACH 阈值、tach presence monitor 或 tach fault logger。`,
      `仅保留读数；零转速/异常转速无日志及告警策略。验证 hwmon 读数可用性。`
    ]];
  }
}

await workbook.recalculate();
const preview = await workbook.render({ sheetName: "端口映射", range: "A4:J50", scale: 1, format: "png" });
await fs.writeFile(`${process.env.TEMP}/port-guide-updated-check.png`, new Uint8Array(await preview.arrayBuffer()));
const check = await workbook.inspect({ kind: "region", sheetId: "端口映射", range: "A4:J50", maxChars: 14000, tableMaxRows: 50, tableMaxCols: 10, tableMaxCellChars: 240 });
console.log(check.ndjson);
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(path);
