"""VGA image selection for the simulator panel.

Virtual media is mounted/ejected in the real BMC Web UI. The simulator only
enumerates the resulting USB gadget and checks read-only SCSI transfers.
"""
import os
from pathlib import Path
import struct
import threading

VIDEO = "/machine/soc/video-engine"
BUILTIN_SCREENS = {"post": "post.jpg", "os": "os.jpg"}
KVM_DIRECTORY = Path(__file__).resolve().parent / "kvm"
JPEG_LIMIT = 192 * 1024  # Below the 800x600 driver's compressed-buffer size.


def validate_jpeg(path):
    data = Path(path).read_bytes() if Path(path).stat().st_size <= JPEG_LIMIT else b""
    if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise ValueError("VGA 图片须为完整 JPEG，大小不超过 192 KiB")
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xff:
            break
        while pos < len(data) and data[pos] == 0xff:
            pos += 1
        if pos >= len(data):
            break
        marker = data[pos]
        pos += 1
        if marker == 0xda:
            break
        length = int.from_bytes(data[pos:pos + 2], "big")
        if length < 2 or pos + length > len(data):
            break
        if marker in (0xc0, 0xc1, 0xc2):
            if length < 8:
                break
            height, width = struct.unpack_from(">HH", data, pos + 3)
            if marker != 0xc0 or (width, height) != (800, 600) or data[pos + 7] != 3:
                raise ValueError("VGA 模型需要 800×600、三分量的 baseline JPEG")
            return data
        pos += length
    raise ValueError("JPEG 缺少有效的 baseline SOF 信息")


class PanelServices:
    def __init__(self, qmp, state_dir, log):
        self.qmp, self.log = qmp, log
        self.directory = Path(state_dir).expanduser().resolve() / "panel-assets"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.vga_override = None
        self.vga_signal = None  # None means follow host power.
        self.video_generation = 0

    def set_vga(self, path):
        path = str(Path(path).expanduser().resolve())
        validate_jpeg(path)
        # QEMU reads the file before we commit the selection.
        with self.lock:
            self.qmp.execute("qom-set", path=VIDEO, property="image", value=path)
            self.vga_override = path
            self.video_generation += 1
        self.log("VGA 图片已选择：" + os.path.basename(path))

    def builtin_vga(self, name):
        if name not in BUILTIN_SCREENS:
            raise ValueError("内置 VGA 图片须选择 post 或 os")
        self.set_vga(KVM_DIRECTORY / BUILTIN_SCREENS[name])

    def auto_vga(self):
        with self.lock:
            self.vga_override = None
            self.vga_signal = None
            self.video_generation += 1

    def set_signal(self, value):
        with self.lock:
            self.qmp.execute("qom-set", path=VIDEO, property="signal", value=value)
            self.vga_signal = value
            self.video_generation += 1

    def state(self):
        with self.lock:
            return {"image": os.path.basename(self.vga_override) if self.vga_override else "自动：POST / OS",
                    "generation": self.video_generation, "signal_override": self.vga_signal,
                    "preview_path": self.vga_override,
                    "fallback_preview_path": str(KVM_DIRECTORY / BUILTIN_SCREENS["post"])}
