#!/usr/bin/env python3
"""Expand the CEB-GNRD layer and what it needs into .tutorial-build/.

Copies the git-tracked files of meta-ctopai/meta-ceb-gnrd, the parent
meta-ctopai layer configuration (conf/layer.conf, the ctopai-openbmc distro)
and quick-start.md into <repo>/.tutorial-build/ceb-gnrd/, keeping the
repository layout. The working-tree contents are copied, so uncommitted
edits come along; untracked scratch files do not.

.tutorial-build/ is git-ignored scratch space. The destination directory
is replaced on every run; nothing else under .tutorial-build/ is touched.

Layout of .tutorial-build/ (local only, not in git):
  ceb-gnrd/                 this script's copy of the layer
  qemu/kvm-usb/             QEMU base/tree for patch 0018, export_integration.py,
                            ref/ (downloaded upstream files for reference)
  qemu/peci-sim/            QEMU base/tree and generator for patch 0019
  linux/peci-temperature/   kernel base/tree, pinned baseline/ files and
                            generator for linux patch 0003
  eds/                      GNR-D EDS-A PDF, extracted text, extractor
  scripts/                  one-off helpers
Each generator writes its patch back into this layer; rerunning one on
unchanged base/tree reproduces the committed patch exactly.

Usage: python3 meta-ctopai/meta-ceb-gnrd/tools/expand-to-tutorial-build.py [DEST]
"""
from pathlib import Path
import shutil
import subprocess
import sys

PATHS = (
    'meta-ctopai/conf',
    'meta-ctopai/meta-ceb-gnrd',
    'meta-ctopai/quick-start.md',
)

repo = Path(subprocess.check_output(
    ['git', 'rev-parse', '--show-toplevel'], cwd=Path(__file__).resolve().parent,
    text=True).strip())
dest = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / '.tutorial-build/ceb-gnrd'
if dest == repo or repo in dest.parents and '.tutorial-build' not in dest.relative_to(repo).parts:
    sys.exit(f'refusing to write inside the repository outside .tutorial-build: {dest}')

files = subprocess.check_output(['git', 'ls-files', '-z', '--', *PATHS], cwd=repo,
                                text=True).split('\0')
if dest.exists():
    shutil.rmtree(dest)
count = 0
for name in filter(None, files):
    source = repo / name
    if not source.is_file():  # deleted in the working tree
        continue
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    count += 1
print(f'{count} files -> {dest}')
