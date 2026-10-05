#!/bin/sh
# Build the QEMU that run-qemu.sh uses: upstream QEMU at a pinned tag with the
# patches in tools/qemu/patches applied, arm-softmmu only, installed under
# ~/qemu-ceb-gnrd/qemu.  Run it on the x86 Linux build server.
#
#   patches/*.patch  the ceb-gnrd board models (README.md has the list).  They are
#   the same patches the OpenBMC build applies to its qemu-system-native, made
#   for QEMU 11.0.2 (the version of the pinned OE-core), so the QEMU that
#   bitbake builds and this one are the same.  Use this script only when there
#   is no Yocto build at hand.
#
# Re-running it resets the source tree to the tag, re-applies the patches and
# rebuilds.  Build dependencies (Ubuntu 22.04 or newer):
#   sudo apt install git build-essential ninja-build pkg-config python3-venv \
#        libglib2.0-dev libpixman-1-dev libslirp-dev flex bison
#
# Environment: QEMU_TAG (default v11.0.2), QEMU_SRC (source tree, default
# ~/qemu-ceb-gnrd/src), PREFIX (install directory, default ~/qemu-ceb-gnrd/qemu),
# QEMU_GIT (default https://gitlab.com/qemu-project/qemu.git), JOBS.

set -e

QEMU_TAG=${QEMU_TAG:-v11.0.2}
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
