#!/bin/sh
# Build the QEMU that run-qemu.sh uses: upstream QEMU at a pinned tag with the
# patches in tools/qemu/patches applied, arm-softmmu only, installed under
# ~/qemu-ceb-gnrd/qemu.  Run it on the x86 Linux build server.
#
#   patches/0001  SCU: AST2600 AHB clock (HCLK), as the Linux clock driver computes it
#   patches/0002  AST2600 PWM/TACH controller: the aspeed-g6-pwm-tach driver reads
#                 fan speeds that follow the PWM duty (QMP: /machine/soc/pwm
#                 fan-max-rpm, fan0-rpm .. fan15-rpm)
#   patches/0003  bmc-host-sim: the host power sequence on the BMC GPIOs inside QEMU
#                 (run-qemu.sh adds it; host-sim.py becomes an optional console)
#
# Re-running it resets the source tree to the tag, re-applies the patches and
# rebuilds.  Build dependencies (Ubuntu 22.04 or newer):
#   sudo apt install git build-essential ninja-build pkg-config python3-venv \
#        libglib2.0-dev libpixman-1-dev libslirp-dev flex bison
#
# Environment: QEMU_TAG (default v11.1.2), QEMU_SRC (source tree, default
# ~/qemu-ceb-gnrd/src), PREFIX (install directory, default ~/qemu-ceb-gnrd/qemu),
# QEMU_GIT (default https://gitlab.com/qemu-project/qemu.git), JOBS.

set -e

QEMU_TAG=${QEMU_TAG:-v11.1.2}
QEMU_GIT=${QEMU_GIT:-https://gitlab.com/qemu-project/qemu.git}
QEMU_SRC=${QEMU_SRC:-$HOME/qemu-ceb-gnrd/src}
PREFIX=${PREFIX:-$HOME/qemu-ceb-gnrd/qemu}
JOBS=${JOBS:-$(nproc)}
PATCHES=$(cd "$(dirname "$0")/patches" && pwd)

if [ ! -d "$QEMU_SRC/.git" ]; then
    mkdir -p "$(dirname "$QEMU_SRC")"
    git clone --depth 1 --branch "$QEMU_TAG" "$QEMU_GIT" "$QEMU_SRC"
fi
cd "$QEMU_SRC"
if ! git rev-parse -q --verify "refs/tags/$QEMU_TAG^{commit}" >/dev/null; then
    git fetch --depth 1 origin tag "$QEMU_TAG"
fi
git am --abort 2>/dev/null || true
git checkout -q --detach "$QEMU_TAG"
git reset -q --hard "$QEMU_TAG"
git -c user.name=build-qemu -c user.email=build-qemu@localhost \
    am -q --committer-date-is-author-date "$PATCHES"/*.patch

mkdir -p build
cd build
../configure --target-list=arm-softmmu --prefix="$PREFIX" \
    --enable-slirp --disable-docs --disable-werror
make -j"$JOBS"
make install

echo
echo "Installed $PREFIX/bin/qemu-system-arm"
"$PREFIX/bin/qemu-system-arm" --version | head -1
