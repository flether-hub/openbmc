# CEB-GNRD change report

Last updated: 2026-10-05 (update this line with every commit)

Purpose: if the assistant that made these changes is unavailable, another AI or
person can continue from here. Every commit is appended: what changed, why, the
commit, how to verify, what is left. Work goes straight to `master`
(no branches or PRs, the user's rule). Firmware is built on the user's Ubuntu x86
build server, not on Windows: nothing below has been compiled on the machine
that wrote it unless it says "verified".

Environment facts
- Repo: `flether-hub/openbmc`, layer `meta-ctopai/meta-ceb-gnrd` (AST2600 + Granite
  Rapids-D board). Build: `. setup ceb-gnrd; bitbake obmc-phosphor-image`.
- Run in QEMU: `./run-qemu.sh` at the repo root (link to
  `meta-ctopai/meta-ceb-gnrd/tools/qemu/run-qemu.sh`). BMC login in QEMU:
  `ssh -p 2222 root@127.0.0.1`, password `0penBmc`; web UI https://127.0.0.1:8443.
- QEMU board models are patches `tools/qemu/patches/NNNN-*.patch` against QEMU
  11.0.2 (the version of the pinned OE-core), applied to `qemu-system-native` by
  `recipes-devtools/qemu/qemu-system-native_%.bbappend` (add every new patch to
  its `SRC_URI`; each patch needs `Upstream-Status:` or `do_patch` fails).
  `tools/qemu/build-qemu.sh` builds the same QEMU outside Yocto.
- Control panel: `tools/qemu/host-sim.py --gui` with `panel_tk.py` (Tk window) or
  `panel.html` (web, port 8800). `README.md` in `tools/qemu/` describes everything.

## QEMU board models (emulator only, no BMC firmware change)

| Commit | What / why | Verify |
|---|---|---|
| `5495773654`, `e3027dd9b2`, `e6abc1e72d` | Patches 0001-0012: AHB clock, AST2600 PWM/TACH fan model, `bmc-host-sim` (host power sequence on the GPIOs, POST codes), settable ADC, GPIO reset tolerance, `crps-psu` PMBus supply, PECI CPU at 0x30, `nct3018y` RTC, VUART + LPC snoop, read-only panel properties. | `bitbake` builds; `./run-qemu.sh`; panel shows fans, PSUs, POST codes. |
| `4457decde3`, `335ebdf791` | Tk panel window (web panel fallback), scroll bar, ADC set over QMP at start. | Panel opens; scroll works. |
| `518c8934d7` | `Upstream-Status` in every patch (Yocto QA failed `do_patch`). | `do_patch` passes. |
| `4147d44053` | Patch 0013: GPIO pin switched to output drives the last written level (LEDs showed stale level). | UID/alert LED follow in the panel. |
| `dbe0abe1aa`, `a25b7bed32` | Patches 0014/0016: AST2600 video engine, 800x600 still picture for the BMC KVM (`tools/qemu/kvm/post.jpg`, `os.jpg`), mode-detect interrupt when the picture appears. | Host on -> web KVM shows the picture. **Not yet confirmed by the user.** |
| `4a131bf841`, `679015d7df` | Patch 0015 `gpio-dir[N]`; panel shows undriven BMC outputs at their board pull-up/down. (679015d7df is from another thread.) | After BMC boot RESET/power lines are green, not orange. |
| `6c61c648b8` | `run-qemu.sh`: `-global driver=aspeed.adc,property=chN-mv,value=...` (short form was split at the first dot); patch 0017: compensation mode reads half scale on every channel (driver offset 0). | ADC sensors read the nominal rails; only D3V0_BAT0 stays critical. |

## BMC firmware fixes found with the emulator (real board has the same bugs)

| Commit | What / why | Verify |
|---|---|---|
| `c9984be953` | DTS: `pwm-fan0..5` + `CONFIG_SENSORS_PWM_FAN`; fansensor logged "no pwm channel found" because aspeed-g6-pwm-tach only registers a pwmchip. | `ls /sys/class/hwmon/*/pwm1` shows 6; no "no pwm channel" in fansensor log. |
| `a1cc889b1b` | `ceb-gnrd-fan-owner.sh` waited for `pwmN` beside `fanN_input`; accept `pwm1` of `pwm-fanN`. Without it `BMC_FAN_BMC_OVERRIDE_N` is never raised. (This commit also swept in another thread's `ceb-gnrd-temp-max.py` edits.) | `gpioinfo | grep OVERRIDE` shows `[used]` and the panel line is green once fan control is up. **User reported the line still low; waiting for `journalctl -u ceb-gnrd-fan-owner`.** |
| `4147d44053` | `ceb-gnrd-psu-detect.sh`: restart psusensor after a PSU is added/removed; poll every 10 s, drop after 2 misses. | Panel: insert PSU2 -> PSU2_* sensors appear within ~10 s; pull -> gone within ~20 s. |
| `36a47cd3bf` | `recipes-phosphor/images/obmc-phosphor-image.bbappend`: `do_generate_static_tar` waits for `linux-yocto-fitimage:do_deploy` (after sstate cleanup: "image-kernel: No such file"). | Clean build packs the image. |
| `77a8624030` | `gpio_defs.json`: UID button name `ID_BTN` (phosphor-buttons only knows that name; `ID_BUTTON` created no button). | `gpioinfo` shows `BMC_UID_BUTTON_N` `[used]`; pressing UID toggles the identify LED. **User: worked once, not after the rebuild; waiting for `gpioinfo`, `gpio_defs.json` and `gpiomon` output.** |
| `d37433c2d8` | `ceb-gnrd-alert-led.py`: intrusion status is the full enum string, compare the last component (every boot logged a false intrusion SEL). | No "Chassis intrusion detected" at boot. |
| `6e5868b21b` | `ceb-gnrd-alert-led.py`: `mapper_sensors()` made tuples then required lists, found no sensors, alarms never lit the alert LED. | D3V0_BAT0 critical -> alert LED red. |

## Open items / known issues
- UID LED after rebuild and fan override line: see the two "waiting" rows above.
- KVM picture (patches 0014/0016) is untested on the real QEMU build.
- D3V0_BAT0: 3.0 V rail with ScaleFactor 1 exceeds the 2.5 V ADC reference; it
  will always read 2.5 V and alarm. Entity-Manager divider/ScaleFactor needs
  checking against the schematic.
- KVM USB keyboard/mouse input (aspeed-vhub) is not modelled; estimated 3x the
  work of the video engine. Not started.
- PCIe/USB picture and PCIe card insert/remove in the panel: offered, no answer.
- Other candidates offered: in-band IPMI over KCS, chassis intrusion model, a real
  x86 QEMU as host, MCTP/PLDM, BIOS update flow.
- The ADC "enter measured volts, divider applied automatically" panel change is
  being made by another thread (uncommitted in the working tree when this was
  written).
