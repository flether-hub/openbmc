#!/usr/bin/env python3
"""Drain a simulator log FIFO; keep current and one backup, 8 MiB each."""
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
limit = 8 * 1024 * 1024
backup = path.with_name(path.name + ".1")
# Trim oversized logs from older launchers before opening in append mode.
for old in (path, backup):
    if old.exists() and old.stat().st_size > limit:
        with old.open("rb") as stream:
            stream.seek(-limit, os.SEEK_END)
            tail = stream.read()
        tmp = old.with_name(old.name + ".bounded")
        tmp.write_bytes(tail)
        os.replace(tmp, old)
stream = path.open("ab", buffering=0)
size = stream.tell()
try:
    while True:
        data = sys.stdin.buffer.read1(65536)
        if not data:
            break
        if size + len(data) > limit:
            stream.close()
            os.replace(path, backup)
            stream = path.open("wb", buffering=0)
            size = 0
        stream.write(data)
        size += len(data)
finally:
    stream.close()
