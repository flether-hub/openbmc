#!/usr/bin/env python3
"""Keep the newest recoverable POST cycle without blocking its daemon."""
import os
from pathlib import Path
import struct
import shutil
import sys

MAX_ARCHIVE_BYTES = 4 * 1024 * 1024


def read_u16(base, name):
    try:
        data = (base / name).read_bytes()
        if len(data) == 2:
            return struct.unpack('<H', data)[0]
    except OSError:
        pass
    return None


def archive(path):
    """Validate the v1 cereal map (u64 timestamp, two byte vectors)."""
    try:
        with path.open('rb') as stream:
            data = stream.read(MAX_ARCHIVE_BYTES + 1)
        if len(data) > MAX_ARCHIVE_BYTES or len(data) < 8:
            return None
        count = struct.unpack_from('<Q', data)[0]
        if not 0 < count <= 100000:
            return None
        offset = 8
        previous = -1
        for _ in range(count):
            timestamp = struct.unpack_from('<Q', data, offset)[0]
            if timestamp <= previous:
                return None
            previous = timestamp
            offset += 8
            for _ in range(2):
                length = struct.unpack_from('<Q', data, offset)[0]
                offset += 8
                if length > len(data) - offset:
                    return None
                offset += length
        if offset != len(data):
            return None
        return data
    except (FileNotFoundError, struct.error):
        return None


def replace_file(path, data):
    temporary = path.with_name('.retention-' + path.name)
    with temporary.open('wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def retain(base):
    if not base.is_dir():
        return
    index = read_u16(base, 'CurrentBootCycleIndex')
    count = read_u16(base, 'CurrentBootCycleCount')
    version = read_u16(base, 'PostCodeDataVersion')
    # Future formats belong to the daemon's version handling; do not rewrite
    # them based on the layout of the current cereal archive.
    if version not in (None, 1):
        return
    marker = base / 'CebGnrdRetentionSlots'
    try:
        converted = marker.read_text(encoding='ascii').strip() == '1'
    except (OSError, UnicodeError):
        converted = False
    current = archive(base / str(index)) if index else None
    if converted and version == 1 and index == 1 and count == 1 and current:
        return

    snapshot = base / '.ceb-retention-snapshot'
    # A daemon may have continued recording after a deferred migration; its
    # valid current archive takes precedence over an older migration snapshot.
    selected = current
    if selected is None and snapshot.is_dir():
        selected = archive(snapshot / '1')
    if selected is None:
        # Prefer the recorded current index even if only count/version was
        # truncated. If the index is damaged, recover the newest valid slot.
        selected = current
        if selected is None:
            candidates = [p for p in base.iterdir() if p.name.isdecimal() and p.is_file()]
            candidates.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
            for path in candidates:
                selected = archive(path)
                if selected is not None:
                    break
        staging = base / '.ceb-retention-pending'
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir()
        if selected is not None:
            replace_file(staging / '1', selected)
        # A valid complete snapshot can recover an interrupted migration.
        if snapshot.exists():
            shutil.rmtree(snapshot)
        os.replace(staging, snapshot)

    if selected is not None:
        replace_file(base / '1', selected)
    for name, value in [('CurrentBootCycleIndex', 1 if selected else 0),
                        ('CurrentBootCycleCount', 1 if selected else 0),
                        ('PostCodeDataVersion', 1)]:
        replace_file(base / name, struct.pack('<H', value))
    for path in base.iterdir():
        if path.name.isdecimal() and path.name != '1':
            path.unlink()
        elif path.name == '1' and selected is None:
            path.unlink()
    replace_file(marker, b'1\n')
    directory = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    if snapshot.exists():
        shutil.rmtree(snapshot)
    print(f'POST history retention: newest {int(selected is not None)} BIOS cycle, max=1')


try:
    retain(Path(f'/var/lib/phosphor-post-code-manager/host{int(sys.argv[1])}'))
except (OSError, ValueError, struct.error) as error:
    # Preserve untouched archives and allow the daemon's own deserializer to
    # handle a damaged/unavailable store. One bad file must not prevent POST.
    print(f'POST history retention deferred: {error}', file=sys.stderr)
