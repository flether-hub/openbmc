#!/usr/bin/env python3
"""Compile real patched NC-SI functions against mocked kernel interfaces.

Usage: python3 test_ncsi_config_retry.py --source /path/to/patched/kernel
Requires a C compiler (CC or --cc); never accesses real interfaces or services.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def function(source, name):
    match = re.search(r"(?m)^[^\n;{}]*\b" + re.escape(name) + r"\([^;{}]*\)\n\{", source)
    if not match:
        raise ValueError("Function definition not found: " + name)
    start, opening = match.start(), match.end() - 1
    # Kernel function closing braces are unindented; nested blocks are not.
    end = source.index("\n}", opening) + 2
    return source[start:end] + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    manage = (args.source / "net/ncsi/ncsi-manage.c").read_text()
    header = (args.source / "net/ncsi/internal.h").read_text()
    driver = (args.source / "drivers/net/ethernet/faraday/ftgmac100.c").read_text()
    states_start = header.index("enum {\n\tncsi_dev_state_major")
    states_end = header.index("\n};", states_start) + 3
    functions = ["ncsi_alloc_request", "ncsi_free_request", "ncsi_suspend_channel",
                 "ncsi_config_cmd_required", "ncsi_config_xmit_cmd",
                 "ncsi_retry_config", "ncsi_configure_channel", "ncsi_reset_dev"]
    extracted = header[states_start:states_end] + "\n" + "\n".join(
        function(manage, name) for name in functions
    )
    extracted += function(driver, "ftgmac100_ncsi_handler")
    fixture = Path(__file__).with_suffix(".c")
    with tempfile.TemporaryDirectory(prefix="ncsi-config-test-", ignore_cleanup_errors=True) as scratch:
        work = Path(scratch)
        (work / "ncsi-functions.inc").write_text(extracted)
        executable = work / ("test.exe" if os.name == "nt" else "test")
        compiler = [args.cc] if Path(args.cc).is_file() else shlex.split(args.cc)
        subprocess.run(compiler + ["-std=gnu11", "-Wall", "-Werror", "-I", str(work),
                                   str(fixture), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
