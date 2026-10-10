#!/bin/sh
# Migrate the former 4 MiB core/journal budgets on the 10 MiB rwfs.
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
# Vacuum only archived journals. Rotate first so the previous active file can
# be reclaimed as well; leave the newest journal data up to the new budget.
journalctl --rotate --vacuum-size=3M --vacuum-files=24 || true
df -k /var/lib /var/log
