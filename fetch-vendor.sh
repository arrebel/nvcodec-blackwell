#!/bin/sh
# fetch-vendor.sh — the NVIDIA trees build.sh compiles against, into vendor/ (not committed: ~50 MB).
#
#   ./fetch-vendor.sh
#
# open-gpu-doc                      class headers (video/...) that document the command stream
# open-gpu-kernel-modules 620.70.06 only two include directories, sparse clone
#
# Reproducibility: the kernel module tag is pinned because the register and class definitions move between
# releases. open-gpu-doc is documentation only; the commit this was tested with is 9fdf5c4.
set -e
cd "$(dirname "$0")"
mkdir -p vendor

if [ ! -f vendor/open-gpu-doc/classes/video/clc9b0.h ]; then
    echo "==> open-gpu-doc"
    git clone --depth 1 https://github.com/NVIDIA/open-gpu-doc.git vendor/open-gpu-doc
fi

K=vendor/open-gpu-kernel-modules
if [ ! -d "$K/src/common/sdk/nvidia/inc" ]; then
    echo "==> open-gpu-kernel-modules 620.70.06 (sparse)"
    rm -rf "$K"
    git clone --depth 1 --filter=blob:none --sparse \
        --branch 620.70.06 https://github.com/NVIDIA/open-gpu-kernel-modules.git "$K"
    git -C "$K" sparse-checkout set \
        src/common/sdk/nvidia/inc \
        src/nvidia/arch/nvalloc/unix/include
fi

echo
echo "vendor/ ready:"
echo "  $(git -C vendor/open-gpu-doc log -1 --format='open-gpu-doc %h')"
echo "  $(git -C $K describe --tags --always 2>/dev/null | sed 's/^/open-gpu-kernel-modules /')"
echo
echo "next: sh build.sh"
