#!/bin/sh
# build-pkg.sh — 把插件打成可直接双击安装的增量包（按 1401 / 2.7.1 构建，2.7.2 也已实机验证）。
#   sh packaging/build-pkg.sh        -> dist/NVDEC-Blackwell-1401-H264-1.0.pkg
set -e
cd "$(dirname "$0")/.."

NAME=NVCODEC-Blackwell-1401
VER=1.2.0
BUNDLE=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
ROOT=packaging/root
STAGE=packaging/stage

[ -f build/libnvdec_h264.dylib ] && [ -f build/libnvencvt.dylib ] || { echo "先构建：sh build.sh（缺 build/libnvdec_h264.dylib 或 build/libnvencvt.dylib）" >&2; exit 1; }

rm -rf "$ROOT" "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$ROOT$BUNDLE" "$ROOT/usr/local/bin" "$ROOT/usr/local/share/nvcodec-blackwell"

for f in libnvdec_h264.dylib libnvencvt.dylib; do
    cp "build/$f" "$ROOT$BUNDLE/$f"
    codesign -f -s - "$ROOT$BUNDLE/$f"
    chmod 755 "$ROOT$BUNDLE/$f"
done
cp packaging/nvdec-uninstall "$ROOT/usr/local/bin/nvdec-uninstall"
chmod 755 "$ROOT/usr/local/bin/nvdec-uninstall"
# MIT 要求二进制副本附带版权与许可声明
cp LICENSE NOTICE README.md "$ROOT/usr/local/share/nvcodec-blackwell/"
chmod 644 "$ROOT/usr/local/share/nvcodec-blackwell/"*
chmod 755 packaging/scripts/preinstall packaging/scripts/postinstall

pkgbuild --root "$ROOT" --scripts packaging/scripts \
         --identifier local.nvdec.blackwell.h264 --version "$VER" \
         --install-location / --ownership recommended \
         "$STAGE/nvdec.pkg"

mkdir -p dist
productbuild --distribution packaging/distribution.xml --resources packaging \
             --package-path "$STAGE" "dist/$NAME.pkg"

rm -rf "$STAGE"
echo "==> dist/$NAME.pkg"
shasum -a 256 "dist/$NAME.pkg"
