#!/usr/bin/env python3
"""Migrate old diagnostic files at boot; monitor rwfs without deleting settings."""
import os
from pathlib import Path
import stat
import sys


def safe_directory(path):
    return all(not p.is_symlink() for p in (path, *path.parents)) and path.is_dir()


def prune_legacy(path, budget):
    if not safe_directory(path):
        return
    files = []
    for root, dirs, names in os.walk(path, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]
        for name in names:
            file = Path(root) / name
            info = file.lstat()
            if stat.S_ISREG(info.st_mode):
                files.append((info.st_mtime_ns, info.st_size, file))
    kept = 0
    for _, size, file in sorted(files, reverse=True):
        if kept + size <= budget:
            kept += size
        else:
            file.unlink()
            print(f"Storage budget: removed old diagnostic archive {file}")


def trim_legacy_logs():
    directory = Path('/var/log')
    if not safe_directory(directory):
        return
    for name, limit, copies in [('bmc-system.log', 524288, 5),
                                ('ipmi_sel', 15360, 1), ('redfish', 65536, 1)]:
        for suffix in ['', *[f'.{n}' for n in range(1, copies + 1)]]:
            path = directory / (name + suffix)
            try:
                fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
            except FileNotFoundError:
                continue
            except OSError as exc:
                print(f"Storage budget: skipped {path}: {exc}")
                continue
            with os.fdopen(fd, 'r+b') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size <= limit:
                    continue
                stream.seek(-limit, os.SEEK_END)
                data = stream.read(limit)
                # Drop the partial first record rather than creating a bogus SEL.
                newline = data.find(b'\n')
                data = data[newline + 1:] if newline >= 0 else b''
                stream.seek(0)
                stream.write(data)
                stream.truncate()
                print(f"Storage budget: trimmed legacy log {path}")


if '--migrate' in sys.argv:
    # No writer uses the persistent journal now; pstore now writes to RAM journal.
    # These are diagnostic archives only, never user settings or firmware files.
    prune_legacy(Path('/var/log/journal'), 1048576)
    prune_legacy(Path('/var/lib/systemd/pstore'), 524288)
    trim_legacy_logs()

usage = os.statvfs('/var/lib')
available = usage.f_bavail * usage.f_frsize
marker = Path('/run/ceb-gnrd-rwfs-low-space')
if available < 2097152:
    if not marker.exists():
        print(f"WARNING rwfs available space is low: {available // 1024} KiB", flush=True)
        marker.touch()
elif available >= 3145728:
    marker.unlink(missing_ok=True)
