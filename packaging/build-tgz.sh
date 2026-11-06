#!/bin/sh
# build-tgz.sh — 打 tar.gz：install.sh + uninstall.sh + README + 两个插件。
#   sh packaging/build-tgz.sh  ->  dist/NVCODEC-Blackwell-1401-1.2.0.tar.gz
set -e
cd "$(dirname "$0")/.."

VER=1.2.0
NAME=NVCODEC-Blackwell-1401-$VER
# 脚本和 README 都在仓库根目录，压缩包里放到顶层
PKG_SRC=.
STAGE=packaging/tgz-stage
OUT=dist/$NAME.tar.gz

[ -f build/libnvdec_h264.dylib ] && [ -f build/libnvencvt.dylib ] || {
    echo "先构建：sh build.sh（缺 build/libnvdec_h264.dylib 或 build/libnvencvt.dylib）" >&2; exit 1; }

rm -rf "$STAGE"; mkdir -p "$STAGE/$NAME/plugins"
cp "$PKG_SRC/install.sh" "$PKG_SRC/uninstall.sh" "$PKG_SRC/README.md" "$PKG_SRC/LICENSE" "$PKG_SRC/NOTICE" "$STAGE/$NAME/"
cp build/libnvdec_h264.dylib build/libnvencvt.dylib "$STAGE/$NAME/plugins/"
chmod 755 "$STAGE/$NAME/install.sh" "$STAGE/$NAME/uninstall.sh"
chmod 755 "$STAGE/$NAME/plugins/"*.dylib

cat > "$STAGE/$NAME/VERSION" <<EOF
version=$VER
tested_driver=2.7.1, 2.7.2
tested_gpu=GB203 (RTX 5070 Ti), GB206 (RTX 5060 Ti)
tested_gpu_pci=0x2c05, 0x2d04
tested_macos=26.7.2
# 代码覆盖 0x2a00-0x2fff 整个 GB20x；实机验证仅 GB203 / GB206 两张卡，其余型号未测。
# 2.7.1 / 0x2c05：5070 Ti 全套基准；2.7.2 / 0x2d04：5060 Ti 1080p 硬解 + 编码器注册（2026-11-06）。
verified_gpus=GB203, GB206
build=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# 打包：去掉扩展属性（隔离标记），root 为属主，解压后权限才稳定
xattr -cr "$STAGE/$NAME" 2>/dev/null || true
mkdir -p dist
( cd "$STAGE" && tar --no-xattrs --owner=0 --group=0 -czf "../../$OUT" "$NAME" 2>/dev/null \
  || tar -czf "../../$OUT" "$NAME" )

rm -rf "$STAGE"
echo "==> $OUT"
tar tzf "$OUT"
shasum -a 256 "$OUT"
