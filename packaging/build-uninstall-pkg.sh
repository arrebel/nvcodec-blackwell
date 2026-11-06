#!/bin/sh
# build-uninstall-pkg.sh — 打一个双击即可卸载的独立安装包（不含任何插件二进制）。
#   sh packaging/build-uninstall-pkg.sh  ->  dist/NVCODEC-Blackwell-1401-Uninstall.pkg
#
# 载荷为空，全部工作在 postinstall 里完成：还原原厂备份 / 关掉驱动开关 / 清理辅助文件。
# 这样即使没装过本插件、或已经手工删过文件，也能安全地跑一遍。
set -e
cd "$(dirname "$0")/.."

VER=$(sed -n 's/^version=//p' VERSION 2>/dev/null | head -1)
[ -n "$VER" ] || VER=1.2.0
NAME=NVCODEC-Blackwell-1401-Uninstall
STAGE=packaging/uninstall-stage

chmod 755 packaging/uninstall-scripts/postinstall
rm -rf "$STAGE"; mkdir -p "$STAGE"

pkgbuild --nopayload --scripts packaging/uninstall-scripts \
         --identifier local.nvdec.blackwell.uninstall --version "$VER" \
         --ownership recommended "$STAGE/uninstall.pkg"

mkdir -p dist
productbuild --distribution packaging/uninstall-distribution.xml \
             --resources packaging \
             --package-path "$STAGE" "dist/$NAME.pkg"

rm -rf "$STAGE"
echo "==> dist/$NAME.pkg"
shasum -a 256 "dist/$NAME.pkg"
