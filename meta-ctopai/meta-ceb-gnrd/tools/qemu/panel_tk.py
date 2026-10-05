"""Tk window of the ceb-gnrd control panel (host-sim.py --gui).

The same panel as panel.html, as a desktop window: the signals between the BMC
and the host with their LEDs and buttons, host control and POST codes, fans,
PSUs, temperatures, ADC, RTC, the host serial console and the event log.
It reads the board state that host-sim.py's Panel polls from QEMU and sends the
same commands as the command line console.  Python 3 with Tk (Ubuntu:
sudo apt install python3-tk).
"""

import threading
import tkinter as tk
from tkinter import ttk

# [name, gpio, property, direction, active low, note]
SIGNALS = [
    ("BMC_CPU_POWER_BUTTON", "GPIOV2", "gpioV2", "b2h", True, "电源键输出（低有效）"),
    ("BMC_CPU_RESET", "GPIOV3", "gpioV3", "b2h", True, "主机复位（低有效）"),
    ("BMC_BIOS_FLASH_SELECT", "GPIOM1", "gpioM1", "b2h", False, "高 = BMC 占用 BIOS Flash"),
    ("BMC_FAN_BMC_OVERRIDE_N", "GPIOI6", "gpioI6", "b2h", False, "高 = BMC 接管风扇"),
    ("BMC_SYS_ALERT_LED", "GPIOI5", "gpioI5", "b2h", False, "告警灯"),
    ("BMC_UID_LED", "GPIOV1", "gpioV1", "b2h", False, "UID 灯"),
    ("BMC_CPU_PWRGD", "GPIOV4", "gpioV4", "h2b", False, "主机电源正常"),
    ("BMC_BIOS_BOOT_OK", "GPIOM7", "gpioM7", "h2b", False, "BIOS POST 完成"),
    ("BMC_POWER_BUTTON_INPUT", "GPIOM2", "gpioM2", "h2b", True, "前面板电源键（低有效）"),
    ("BMC_UID_BUTTON_N", "GPIOV0", "gpioV0", "h2b", True, "UID 按键（低有效）"),
]
HOST_LABELS = {"gpioV2": "电源键", "gpioV3": "复位", "gpioM1": "BIOS Flash",
               "gpioI6": "风扇控制", "gpioI5": "告警灯", "gpioV1": "UID 灯",
               "gpioV4": "电源 PWRGD", "gpioM7": "BIOS BOOT_OK"}
BUSES = [("PECI", "CPU / DIMM 温度", "peci"), ("eSPI / LPC 80h", "POST 码", "post"),
         ("VUART (COM1)", "SOL 串口", "uart"), ("PWM / TACH", "6 个风扇", "fan"),
         ("I2C", "温度、PSU、FRU、RTC", "i2c")]
STATES = {"off": "关机", "starting": "上电中", "post": "POST 中", "on": "运行",
          "shutting-down": "关机中"}
STATE_COLOURS = {"off": "#9aa3b2", "starting": "#f59e0b", "post": "#f59e0b",
                 "on": "#22c55e", "shutting-down": "#f59e0b"}
TEMP_NAMES = [("inlet", "进风 (0x48)"), ("outlet", "出风 (0x49)"),
              ("pcie", "PCIe (0x4a)"), ("m2", "M.2 (0x4b)")]

ON, OFF, ACT, ALERT, BLUE, WIRE = "#22c55e", "#cbd2dc", "#f59e0b", "#ef4444", "#3b82f6", "#9aa3b2"


class PanelWindow:
    def __init__(self, panel, command):
        """panel: host-sim.py Panel (its .state is the polled board state);
        command(text) runs one console command and raises on bad input."""
        self.panel = panel
        self.command = command
        self.root = tk.Tk()
        self.root.title("CEB-GNRD 模拟控制面板")
        self.root.geometry("1180x900")
        self.term_pos = 0
        self.drawn = {}
        self._build()
        self.root.after(300, self.refresh)

    # ---- helpers ----------------------------------------------------------
    def run(self, text):
        def work():
            try:
                self.command(text)
                msg = ""
            except Exception as exc:          # shown in the status bar
                msg = str(exc)
            self.root.after(0, lambda: self.status.set(msg))
        threading.Thread(target=work, daemon=True).start()

    def button(self, parent, text, cmd, **kw):
        return ttk.Button(parent, text=text,
                          command=(lambda: self.run(cmd() if callable(cmd) else cmd)), **kw)

    def changed(self, name, data):
        if self.drawn.get(name) == data:
            return False
        self.drawn[name] = data
        return True

    # ---- layout -------------------------------------------------------------
    def _build(self):
        top = ttk.Frame(self.root, padding=(10, 6))
        top.pack(fill="x")
        ttk.Label(top, text="CEB-GNRD 模拟控制面板", font=("", 13, "bold")).pack(side="left")
        ttk.Label(top, text="   主机：").pack(side="left")
        self.state_lbl = tk.Label(top, text="--", fg="white", bg=OFF, padx=10,
                                  font=("", 10, "bold"))
        self.state_lbl.pack(side="left")
        self.mode_lbl = ttk.Label(top, text="", foreground="#6b7280")
        self.mode_lbl.pack(side="left", padx=12)

        self.canvas = tk.Canvas(self.root, height=430, background="#ffffff",
                                highlightthickness=0)
        self.canvas.pack(fill="x", padx=10)
        self._build_diagram()

        tabs = ttk.Notebook(self.root)
        tabs.pack(fill="both", expand=True, padx=10, pady=6)
        self._tab_host(tabs)
        self._tab_fans(tabs)
        self._tab_psus(tabs)
        self._tab_sensors(tabs)
        self._tab_console(tabs)
        self._tab_log(tabs)

        self.status = tk.StringVar()
        ttk.Label(self.root, textvariable=self.status, foreground=ALERT).pack(
            fill="x", padx=10, pady=(0, 4))

    def _build_diagram(self):
        c = self.canvas
        bx, bw, hx, hw = 20, 210, 900, 240
        top, step = 40, 32
        mid = (bx + bw + hx) // 2
        bottom = top + (len(SIGNALS) + len(BUSES)) * step + 10
        c.configure(height=bottom + 10)
        c.create_rectangle(bx, 6, bx + bw, bottom, outline="#d6d9e0", fill="#f4f5f7", width=2)
        c.create_text(bx + 12, 22, text="AST2600 BMC", anchor="w", font=("", 11, "bold"))
        c.create_rectangle(hx, 6, hx + hw, bottom, outline="#d6d9e0", fill="#f4f5f7", width=2)
        c.create_text(hx + 12, 22, text="主机主板 (GNR-D / CPLD)", anchor="w",
                      font=("", 11, "bold"))
        self.wires, self.leds = {}, {}
        for i, (name, gpio, key, direction, low, note) in enumerate(SIGNALS):
            y = top + i * step + 10
            c.create_text(bx + 12, y, text=gpio, anchor="w", fill="#6b7280",
                          font=("Courier", 9))
            self.leds[key] = (
                c.create_oval(bx + bw - 22, y - 7, bx + bw - 8, y + 7, fill=OFF, outline=""),
                c.create_oval(hx + 8, y - 7, hx + 22, y + 7, fill=OFF, outline=""))
            self.wires[key] = c.create_line(bx + bw, y, hx, y, fill=WIRE, width=2,
                                            arrow="last" if direction == "b2h" else "first")
            c.create_text(mid, y - 7, text=name, font=("", 9))
            c.create_text(mid, y + 8, text=note, fill="#6b7280", font=("", 8))
            if key in HOST_LABELS:
                c.create_text(hx + 30, y, text=HOST_LABELS[key], anchor="w", font=("", 9))
        for key, text, cmd in (("gpioM2", "按前面板电源键", "power"),
                               ("gpioV0", "按 UID 键", "uid")):
            i = [s[2] for s in SIGNALS].index(key)
            y = top + i * step + 10
            c.create_window(hx + 30, y, anchor="w",
                            window=self.button(c, text, cmd, width=16))
        self.bus_vals = {}
        for j, (name, note, key) in enumerate(BUSES):
            y = top + (len(SIGNALS) + j) * step + 16
            c.create_line(bx + bw, y, hx, y, fill=WIRE, width=2, dash=(6, 4))
            c.create_text(mid, y - 7, text=name, font=("", 9))
            c.create_text(mid, y + 8, text=note, fill="#6b7280", font=("", 8))
            self.bus_vals[key] = c.create_text(hx + 12, y, text="", anchor="w",
                                               fill="#6b7280", font=("Courier", 9))

    def _tab_host(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="主机控制 / POST 码")
        left = ttk.LabelFrame(f, text="主机控制", padding=8)
        left.pack(side="left", fill="both", expand=True)
        row = ttk.Frame(left); row.pack(anchor="w", pady=3)
        self.button(row, "前面板电源键（短按）", "power").pack(side="left", padx=2)
        self.button(row, "长按 5 s（强制关机）", "power-hold").pack(side="left", padx=2)
        row = ttk.Frame(left); row.pack(anchor="w", pady=3)
        self.button(row, "UID 按键", "uid").pack(side="left", padx=2)
        self.button(row, "主机掉电（PWRGD 突然掉）", "powerfail").pack(side="left", padx=2)
        row = ttk.Frame(left); row.pack(anchor="w", pady=3)
        self.hang_btn = self.button(row, "BIOS 卡死：关",
                                    lambda: "hang off" if self.panel.state.get("hang") else "hang on")
        self.hang_btn.pack(side="left", padx=2)
        ttk.Label(row, text="下一次 POST 起生效，POST 码停在 0x92",
                  foreground="#6b7280").pack(side="left", padx=6)
        row = ttk.Frame(left); row.pack(anchor="w", pady=3)
        self.post_s = tk.StringVar(value="20")
        self.shut_s = tk.StringVar(value="10")
        ttk.Label(row, text="POST 时间").pack(side="left")
        ttk.Entry(row, textvariable=self.post_s, width=5).pack(side="left")
        ttk.Label(row, text="s   关机时间").pack(side="left")
        ttk.Entry(row, textvariable=self.shut_s, width=5).pack(side="left")
        ttk.Label(row, text="s").pack(side="left")
        ttk.Button(row, text="设置", command=lambda: (
            self.run("post " + self.post_s.get()),
            self.run("shutdown " + self.shut_s.get()))).pack(side="left", padx=6)

        right = ttk.LabelFrame(f, text="80 端口 POST 码（LPC snoop）", padding=8)
        right.pack(side="left", fill="both", expand=True, padx=(10, 0))
        self.post_lbl = tk.Label(right, text="--", font=("Courier", 40, "bold"),
                                 fg="#ff4d4d", bg="#0b0f14", width=4)
        self.post_lbl.pack(anchor="w")
        row = ttk.Frame(right); row.pack(anchor="w", pady=4)
        ttk.Label(row, text="手动写入 0x").pack(side="left")
        self.pc_in = tk.StringVar(value="A0")
        ttk.Entry(row, textvariable=self.pc_in, width=4).pack(side="left")
        self.button(row, "写 80h", lambda: "postcode " + self.pc_in.get()).pack(side="left", padx=4)
        self.post_hist = tk.Text(right, height=8, width=28, font=("Courier", 9))
        self.post_hist.pack(fill="both", expand=True)

    def _tab_fans(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="风扇")
        self.fan_rows = []
        for i in range(6):
            box = ttk.LabelFrame(f, text="SYS_FAN%d" % i, padding=6)
            box.grid(row=i // 3, column=i % 3, sticky="nsew", padx=4, pady=4)
            rpm = ttk.Label(box, text="--", font=("Courier", 16, "bold"))
            rpm.pack(anchor="w")
            bar = ttk.Progressbar(box, maximum=100, length=200)
            bar.pack(anchor="w", pady=2)
            info = ttk.Label(box, text="", foreground="#6b7280")
            info.pack(anchor="w")
            row = ttk.Frame(box); row.pack(anchor="w", pady=2)
            self.button(row, "坏掉", "fan %d 0" % i).pack(side="left", padx=2)
            self.button(row, "修好", "fan %d auto" % i).pack(side="left", padx=2)
            self.button(row, "低速 2000", "fan %d 2000" % i).pack(side="left", padx=2)
            self.fan_rows.append((box, rpm, bar, info))
        row = ttk.Frame(f); row.grid(row=2, column=0, columnspan=3, sticky="w", pady=6)
        ttk.Label(row, text="100% PWM 时转速").pack(side="left")
        self.fan_max = tk.StringVar(value="12000")
        ttk.Entry(row, textvariable=self.fan_max, width=7).pack(side="left")
        self.button(row, "设置", lambda: "fan max " + self.fan_max.get()).pack(side="left", padx=4)
        self.button(row, "全部恢复正常", "fan all auto").pack(side="left", padx=4)
        for col in range(3):
            f.columnconfigure(col, weight=1)

    def _tab_psus(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="电源 PSU")
        self.psu_rows = []
        for i in range(3):
            box = ttk.LabelFrame(f, text="PSU%d (0x%02x)" % (i, 0x58 + i), padding=8)
            box.grid(row=0, column=i, sticky="nsew", padx=4)
            state = ttk.Label(box, text="--", font=("", 11, "bold"))
            state.pack(anchor="w")
            info = ttk.Label(box, text="", foreground="#6b7280", justify="left")
            info.pack(anchor="w", pady=4)
            row = ttk.Frame(box); row.pack(anchor="w")
            self.button(row, "插入", "psu %d in" % i).pack(side="left", padx=2)
            self.button(row, "拔出", "psu %d out" % i).pack(side="left", padx=2)
            row = ttk.Frame(box); row.pack(anchor="w", pady=2)
            self.button(row, "拔 AC", "psu %d ac off" % i).pack(side="left", padx=2)
            self.button(row, "接 AC", "psu %d ac on" % i).pack(side="left", padx=2)
            self.button(row, "过热 85°C", "psu %d temp 85" % i).pack(side="left", padx=2)
            row = ttk.Frame(box); row.pack(anchor="w", pady=2)
            ttk.Label(row, text="负载 W").pack(side="left")
            load = tk.Scale(row, from_=0, to=1600, resolution=10, orient="horizontal",
                            length=180, showvalue=True)
            load.pack(side="left")
            load.bind("<ButtonRelease-1>",
                      lambda e, i=i, s=load: self.run("psu %d load %d" % (i, s.get())))
            self.psu_rows.append((box, state, info, load))
            f.columnconfigure(i, weight=1)

    def _tab_sensors(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="温度 / ADC / RTC")
        temps = ttk.LabelFrame(f, text="温度 °C（松开滑块即生效）", padding=8)
        temps.pack(side="left", fill="y")
        self.temp_scales = {}
        rows = TEMP_NAMES + [("cpu", "CPU 封装（PECI）"), ("dimm", "DIMM（PECI）")]
        for key, label in rows:
            ttk.Label(temps, text=label).pack(anchor="w")
            sc = tk.Scale(temps, from_=0, to=110, orient="horizontal", length=220)
            sc.pack(anchor="w")
            cmd = ("temp %s" % key) if key not in ("cpu", "dimm") else key
            sc.bind("<ButtonRelease-1>", lambda e, c=cmd, s=sc: self.run("%s %d" % (c, s.get())))
            self.temp_scales[key] = sc

        adc = ttk.LabelFrame(f, text="ADC（引脚电压 × 分压比 = 电源轨）", padding=8)
        adc.pack(side="left", fill="both", expand=True, padx=10)
        self.adc_rows = []
        for i in range(16):
            name = ttk.Label(adc, text="", font=("Courier", 9))
            name.grid(row=i, column=0, sticky="w")
            rail = ttk.Label(adc, text="", font=("Courier", 9), width=22)
            rail.grid(row=i, column=1, sticky="w")
            mv = tk.StringVar()
            ttk.Entry(adc, textvariable=mv, width=7).grid(row=i, column=2)
            self.button(adc, "设置", lambda i=i, mv=mv: "adc %d %s" % (i, mv.get()),
                        width=5).grid(row=i, column=3, padx=2)
            self.adc_rows.append((name, rail, mv))

        rtc = ttk.LabelFrame(f, text="RTC NCT3015Y", padding=8)
        rtc.pack(side="left", fill="y")
        self.rtc_lbl = ttk.Label(rtc, text="电池：--")
        self.rtc_lbl.pack(anchor="w")
        self.button(rtc, "电池正常", "rtc battery ok").pack(anchor="w", pady=2)
        self.button(rtc, "电池没电", "rtc battery low").pack(anchor="w", pady=2)

    def _tab_console(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="主机串口 (SOL)")
        ttk.Label(f, text="本窗口扮演主机 COM1：BMC 的 SOL 输入显示在这里，下框输入回车后由主机发给 BMC",
                  foreground="#6b7280").pack(anchor="w")
        self.term = tk.Text(f, height=16, bg="#0b0f14", fg="#d1e7d1",
                            insertbackground="#d1e7d1", font=("Courier", 10))
        self.term.pack(fill="both", expand=True)
        self.term_in = tk.StringVar()
        entry = ttk.Entry(f, textvariable=self.term_in, font=("Courier", 10))
        entry.pack(fill="x", pady=4)
        entry.bind("<Return>", self._send_console)

    def _tab_log(self, tabs):
        f = ttk.Frame(tabs, padding=10)
        tabs.add(f, text="事件日志")
        self.log = tk.Text(f, height=16, font=("Courier", 9))
        self.log.pack(fill="both", expand=True)

    def _send_console(self, _event):
        text = self.term_in.get() + "\n"
        self.term_in.set("")
        if self.panel.console:
            threading.Thread(target=self.panel.console.send, args=(text,), daemon=True).start()

    # ---- refresh -----------------------------------------------------------
    def refresh(self):
        try:
            self._refresh()
        finally:
            self.root.after(500, self.refresh)

    def _refresh(self):
        st = self.panel.state
        if not st:
            return
        host = st.get("host", "off")
        self.state_lbl.configure(text=STATES.get(host, host),
                                 bg=STATE_COLOURS.get(host, OFF))
        self.mode_lbl.configure(text="主机时序在 QEMU 内运行（bmc-host-sim）" if st.get("builtin")
                                else "原版 QEMU：主机时序由本程序扮演")
        self.hang_btn.configure(text="BIOS 卡死：开（点击关闭）" if st.get("hang") else "BIOS 卡死：关")

        # diagram
        pins = st.get("pins", {})
        for name, gpio, key, direction, low, note in SIGNALS:
            v = pins.get(key)
            asserted = low and v is False
            colour = ON if v else OFF
            if key == "gpioI5" and v:
                colour = ALERT
            if key == "gpioV1" and v:
                colour = BLUE
            if asserted:
                colour = ACT
            for led in self.leds[key]:
                self.canvas.itemconfigure(led, fill=colour)
            self.canvas.itemconfigure(self.wires[key], fill=ACT if asserted else (ON if v else WIRE),
                                      width=3 if asserted else 2)
        peci = st.get("peci", {})
        online = peci.get("cpu-online")
        self.canvas.itemconfigure(self.bus_vals["peci"], text="" if online is None else (
            "CPU %.0f°C" % (peci["cpu-temp-mc"] / 1000) if online else "CPU 无响应"))
        post = st.get("post")
        self.canvas.itemconfigure(self.bus_vals["post"],
                                  text="" if post is None else "POST 0x%02X" % post)
        fans = st.get("fans", [])
        self.canvas.itemconfigure(self.bus_vals["fan"], text=" ".join(
            "%.1fk" % (f["rpm"] / 1000) for f in fans if f.get("rpm") is not None))

        # host tab
        self.post_lbl.configure(text="--" if post is None else "%02X" % post)
        if self.changed("posts", st.get("posts")):
            self.post_hist.delete("1.0", "end")
            for t, code in reversed(st.get("posts", [])):
                self.post_hist.insert("end", "%s  0x%02X\n" % (t, code))

        # fans
        if self.changed("fans", fans):
            for (box, rpm, bar, info), f in zip(self.fan_rows, fans):
                failed = f.get("fixed") == 0
                rpm.configure(text="-- RPM" if f.get("rpm") is None else "%d RPM" % f["rpm"],
                              foreground=ALERT if failed else "")
                bar["value"] = f.get("duty") or 0
                info.configure(text=("故障（0 RPM）  " if failed else "") +
                               "PWM %s%%" % f.get("duty"))

        # PSUs
        psus = st.get("psus", [])
        if self.changed("psus", psus):
            for (box, state, info, load), p in zip(self.psu_rows, psus):
                if p.get("model") != "crps":
                    state.configure(text="原版 QEMU：只有电压读数" if p.get("model") else "未配置",
                                    foreground="")
                    info.configure(text="")
                    continue
                present, ac = p["present"], not p["ac-lost"]
                state.configure(text="正常" if present and ac else ("AC 掉电" if present else "未插"),
                                foreground=ON if present and ac else (ALERT if present else "#6b7280"))
                if present:
                    pout = p["pout-mw"] / 1000 if ac else 0
                    pin = p["pout-mw"] * 100 / max(p["efficiency"], 1) / 1000 if ac else 0
                    info.configure(text="输出 %.0f W / %.2f V\n输入 %.0f V / %.0f W\n温度 %.0f°C" % (
                        pout, p["vout-mv"] / 1000 if ac else 0, p["vin-mv"] / 1000 if ac else 0,
                        pin, p["temp2-mc"] / 1000))
                    load.set(p["pout-mw"] // 1000)
                else:
                    info.configure(text="")

        # temperatures, ADC, RTC (not while the user drags a slider)
        temps = dict(st.get("temps", {}))
        if peci.get("cpu-temp-mc") is not None:
            temps["cpu"] = peci["cpu-temp-mc"] / 1000
            temps["dimm"] = peci["dimm-temp-mc"] / 1000
        focus = self.root.focus_get()
        if self.changed("temps", temps):
            for key, sc in self.temp_scales.items():
                if key in temps and sc is not focus:
                    sc.set(temps[key])
        adc = st.get("adc", [])
        if self.changed("adc", adc):
            for (name, rail, mv), a in zip(self.adc_rows, adc):
                name.configure(text="%2d %s" % (adc.index(a), a["name"]))
                if a["mv"] is None:
                    rail.configure(text="原版 QEMU")
                    continue
                volts = min(a["mv"], 2500) * a["scale"] / 1000
                rail.configure(text="跳变" if a["mv"] < 0 else "%.2f V%s" % (
                    volts, "  超出 2.5V 参考" if a["mv"] > 2500 else ""))
                mv.set(str(a["mv"]))
        rb = st.get("rtc_battery")
        self.rtc_lbl.configure(text="电池：--" if rb is None else ("电池：正常" if rb else "电池：没电"))

        # console and log
        if self.panel.console:
            self.term_pos, text = self.panel.console.since(self.term_pos)
            if text:
                self.term.insert("end", text.replace("\r", ""))
                self.term.see("end")
        log = st.get("log", [])
        if self.changed("log", log):
            self.log.delete("1.0", "end")
            self.log.insert("end", "\n".join(log))
            self.log.see("end")

    def mainloop(self):
        self.root.mainloop()
