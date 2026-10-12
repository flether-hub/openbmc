#!/usr/bin/env python3
"""Keep only the newest POST cycle before its daemon starts."""
import os
from pathlib import Path
import struct
import shutil
import sys

host = int(sys.argv[1])
base = Path(f"/var/lib/phosphor-post-code-manager/host{host}")
if not base.is_dir():
    sys.exit(0)
marker = base / "CebGnrdRetentionSlots"
if marker.exists() and marker.read_text(encoding="ascii").strip() == "1":
    sys.exit(0)
def read_u16(name):
    path = base / name
    if not path.exists():
        return 0
    data = path.read_bytes()
    if len(data) != 2:
        raise RuntimeError(f"Invalid POST metadata: {path}")
    return struct.unpack("<H", data)[0]
snapshot = base / ".ceb-retention-snapshot"
archives = []
if snapshot.is_dir():
    archives = [p.read_bytes() for p in sorted(snapshot.iterdir()) if p.is_file()][:1]
else:
    index = read_u16("CurrentBootCycleIndex")
    count = read_u16("CurrentBootCycleCount")
    # The physical index names the newest archive in both old 100-slot and
    # two-slot rings. Preserve it without parsing variable-size POST payloads.
    if count and index:
        path = base / str(index)
        if path.exists():
            archives.append(path.read_bytes())
    staging = base / ".ceb-retention-pending"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    for slot, data in enumerate(archives, 1):
        (staging / str(slot)).write_bytes(data)
    # A complete snapshot survives interruption while replacing ring files.
    os.replace(staging, snapshot)
# Read the newest archive before replacing the ring slot. Atomic replacement
# prevents partially written files on interruption; cleanup follows writes.
for slot, data in enumerate(archives, 1):
    tmp = base / f".retention-{slot}"
    tmp.write_bytes(data)
    os.replace(tmp, base / str(slot))
for name, value in [("CurrentBootCycleIndex", 1 if archives else 0),
                    ("CurrentBootCycleCount", len(archives))]:
    tmp = base / f".{name}"
    tmp.write_bytes(struct.pack("<H", value))
    os.replace(tmp, base / name)
for path in base.iterdir():
    if path.name.isdecimal() and int(path.name) > len(archives):
        path.unlink()
marker.write_text("1\n", encoding="ascii")
shutil.rmtree(snapshot)
print(f"POST history retention: newest {len(archives)} BIOS cycle, max=1")
