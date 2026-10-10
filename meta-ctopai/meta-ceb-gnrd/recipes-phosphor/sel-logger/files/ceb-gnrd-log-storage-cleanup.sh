#!/bin/sh
# Remove legacy core payloads; persistent warning text is rotated separately.
# Core payloads are now disabled; their crash summaries remain in journal.
set -eu
removed=0
for file in /var/lib/systemd/coredump/core.*; do
    [ -f "$file" ] || continue
    [ ! -L "$file" ] || continue
    rm -f -- "$file"
    removed=$((removed + 1))
done
echo "Log storage: removed $removed old core payloads; rwfs=14 MiB"
# Retain a bounded amount of old binary diagnostics and trim oversized legacy
# text files before rsyslog opens them. Normal rotation runs inside rsyslog.
/usr/libexec/ceb-gnrd-storage-budget --migrate
# Vacuum only the volatile journal.
journalctl --directory=/run/log/journal --vacuum-size=8M --vacuum-files=8 || true
df -k /var/lib /var/log
