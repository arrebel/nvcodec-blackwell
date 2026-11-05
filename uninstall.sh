#!/bin/sh
# uninstall.sh — 停用这套插件，把 H.264 交回系统实现。
#
# 为什么可能不是“删文件”：/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS 带 SIP 的
# restricted 标志，root 也不能在这个目录里增删文件（只有安装器可以）。所以回退有两层：
#   1) 有原厂备份 -> 把原厂 libnvdec_h264.dylib 拷回去（覆盖内容是允许的）；
#   2) 没有备份   -> 用驱动自己的配置开关让插件不注册：
#        NVMTL_NO_NVDEC=1  不注册外挂 H.264 解码插件（HEVC 解码和其它功能不受影响）
#        NVMTL_NVENCVT=0   外挂编码插件自己不注册
set -e
cd "$(dirname "$0")"

BUNDLE=${NVCODEC_BUNDLE:-/Library/GPUBundles/NVMTLDriver.bundle}
B="$BUNDLE/Contents/MacOS"
CONF=${NVCODEC_CONF:-/Library/GPUBundles/nvmtl/nvrm610.conf}

die() { echo "错误：$*" >&2; exit 1; }
info() { echo "  $*"; }
# 只认编译进插件的标记串（原厂插件的日志前缀和我们一样，分不出来）
is_ours() { [ -f "$1" ] && strings -a "$1" 2>/dev/null | grep -q "nvcodec-blk-1401"; }

[ "$(id -u)" = 0 ] || [ -n "$NVCODEC_NO_ROOT_CHECK" ] || die "要 root：sudo ./uninstall.sh"
[ -d "$B" ] || die "找不到 ${B}（驱动没装？）"

RESTORED=0
if [ -f "$B/libnvdec_h264.dylib.vendor" ] && ! is_ours "$B/libnvdec_h264.dylib.vendor"; then
    cp -p "$B/libnvdec_h264.dylib.vendor" "$B/libnvdec_h264.dylib"
    chown root:wheel "$B/libnvdec_h264.dylib" 2>/dev/null || true
    chmod 755 "$B/libnvdec_h264.dylib" 2>/dev/null || true
    info "已还原原厂 libnvdec_h264.dylib"
    RESTORED=1
else
    info "没有可用的原厂备份（本机一直都是覆盖安装的），改用配置开关停用解码插件"
fi

if [ -f "$CONF" ]; then
    [ -f "$CONF.orig" ] || cp -p "$CONF" "$CONF.orig"
    KEEP=$(grep -vE '^(NVMTL_NVENCVT|NVMTL_NO_NVDEC)=' "$CONF" || true)
    if [ "$RESTORED" = 1 ]; then
        # 原厂插件回来了，就不能再挂 NO_NVDEC，否则连原厂解码一起停掉
        printf '%s\nNVMTL_NVENCVT=0\n' "$KEEP" > "$CONF"
    else
        printf '%s\nNVMTL_NO_NVDEC=1\nNVMTL_NVENCVT=0\n' "$KEEP" > "$CONF"
    fi
    chown root:wheel "$CONF" 2>/dev/null || true
    chmod 644 "$CONF" 2>/dev/null || true
    info "配置已更新 ${CONF}（编码插件停用$( [ "$RESTORED" = 1 ] || echo "、解码插件停用" )）"
else
    info "没有 ${CONF}：无法用开关停用；请重装驱动把插件换成原厂的"
fi

killall VTDecoderXPCService 2>/dev/null || true
killall VTEncoderXPCService 2>/dev/null || true

echo
echo "已回退。现在 H.264 由系统/原厂插件处理。"
echo "想再装上：sudo ./install.sh"
