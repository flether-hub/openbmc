#!/bin/sh
# Run on the BMC. 0 = current QEMU model (default); 1 = physical board.
# BMC_PASSWORD='...' ceb-gnrd-check 0
# CEB_CHECK_CLEAR_LOGS=1 enables destructive EventLog ClearLog only.
set -u
case "${1:-0}" in
    0|1) ;;
    -h|--help)
        echo "Usage: BMC_PASSWORD='...' ceb-gnrd-check [0|1]"
        echo "0: current QEMU; 1: board. Default checks are read-only."
        echo "Results: /tmp/ceb-gnrd-check/report.txt and /tmp/ceb-gnrd-check.tar.gz"
        echo "CEB_CHECK_CLEAR_LOGS=1 explicitly enables EventLog deletion."
        exit 0 ;;
    *) echo "Expected 0 (QEMU) or 1 (board)" >&2; exit 2 ;;
esac
lock=/run/ceb-gnrd-check.lock
if ! mkdir "$lock" 2>/dev/null; then
    echo "Another check is running, or a stale lock exists: $lock" >&2
    exit 2
fi
trap 'rmdir "$lock" 2>/dev/null' 0
trap 'exit 130' INT
trap 'exit 143' TERM
python3 /usr/libexec/ceb-gnrd-check.py "${1:-0}"
exit "$?"
