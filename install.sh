#!/bin/sh
# install.sh — H.264 decode/encode plug-ins for Blackwell, into an existing NullMoth NVMTLDriver bundle.
#               Blackwell（RTX 50 系）的 H.264 硬解 / 硬编插件。
#
#   sudo ./install.sh              安装（或覆盖升级）
#   sudo ./install.sh --check      只体检，不改任何文件（升级驱动后先跑这个）
#   sudo ./install.sh --uninstall  停用并尽量还原原厂插件
#
# 可覆盖的路径（自测 / 非标准安装位置用）：
#   NVCODEC_BUNDLE=/Library/GPUBundles/NVMTLDriver.bundle
#   NVCODEC_CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
set -e
cd "$(dirname "$0")"

BUNDLE=${NVCODEC_BUNDLE:-/Library/GPUBundles/NVMTLDriver.bundle}
B="$BUNDLE/Contents/MacOS"
CONF=${NVCODEC_CONF:-/Library/GPUBundles/nvmtl/nvrm610.conf}
# 仓库里直接跑用 build/，打好的压缩包里用 plugins/
SRC="$PWD/plugins"
[ -f "$SRC/libnvdec_h264.dylib" ] || SRC="$PWD/build"
TESTED_DRIVER=2.7.1

die() { echo "错误：$*" >&2; exit 1; }
info() { echo "  $*"; }

# 认文件是不是我们的：只认编译进插件的标记串（原厂插件的日志前缀和我们一样，靠它分不出来）
is_ours() { [ -f "$1" ] && strings -a "$1" 2>/dev/null | grep -q "nvcodec-blk-1401"; }
our_version() {
    [ -f "$1" ] || return 0
    strings -a "$1" 2>/dev/null | sed -n 's/.*nvcodec-blk-1401 [a-z]* \([0-9][^ ]*\).*/\1/p' | head -1
}
conf_get() { [ -f "$CONF" ] && grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r'; }

driver_version() {
    v=$(kmutil showloaded --list-only 2>/dev/null | sed -n 's/.*com\.nullmoth\.NVRM (\([^)]*\)).*/\1/p' | tail -1)
    [ -n "$v" ] || v=$(defaults read /Library/Extensions/NVRM.kext/Contents/Info CFBundleVersion 2>/dev/null || true)
    printf '%s' "$v"
}

# 只认 VGA class（0x030000）的那块卡，别把 HDMI 音频功能当成显卡
gpu_device_ids() {
    ioreg -r -c IOPCIDevice -w0 2>/dev/null | awk '
    function emit(b,   d) {
        if (b !~ /"vendor-id" = <de100000>/) return
        if (b !~ /"class-code" = <00000300>/) return
        d = b; sub(/.*"device-id" = </, "", d); sub(/>.*/, "", d)
        if (length(d) >= 4) printf "0x%s%s\n", substr(d, 3, 2), substr(d, 1, 2)
    }
    /^[ \t]*[|+ ]*-o / { emit(block); block = "" }
    { block = block "\n" $0 }
    END { emit(block) }'
}

case "$1" in
--uninstall) [ "$(id -u)" = 0 ] || die "要 root：sudo ./install.sh --uninstall"
             exec sh "$PWD/uninstall.sh" ;;
esac

[ -d "$B" ] || die "找不到驱动目录：
  $B
  先装 nullmoth 的 1401 / NVRM 驱动（NVMTLDriver.bundle 必须已经存在）。"

DRV=$(driver_version)
echo "驱动：${DRV:-未知}（本插件在 $TESTED_DRIVER 上验证过）"
if [ -n "$DRV" ] && [ "$DRV" != "$TESTED_DRIVER" ]; then
    echo "  提示：版本和验证过的不同。插件是按文件名接进驱动目录的，通常照旧能用；"
    echo "        装完跑一次编解码测试确认，出问题用 --uninstall 回退。"
fi

IDS=$(gpu_device_ids | tr '\n' ' ')
if [ -z "$IDS" ]; then
    echo "显卡：没找到 NVIDIA 显卡（驱动没加载？）"
else
    echo "显卡：$IDS"
    for id in $IDS; do
        n=$((id))
        if [ $n -ge $((0x2a00)) ] && [ $n -le $((0x2fff)) ]; then
            info "$id 属于 Blackwell（GB20x），代码路径适用"
            echo "        注意：本插件已在 RTX 5070 Ti（GB203）与 RTX 5060 Ti（GB206）上实机验证过，其他型号请装完跑一次实测。"
        else
            info "$id 不是 Blackwell，插件会自己选择不注册（不会弄坏系统）"
        fi
    done
fi

MISS=""
[ -f "$SRC/libnvdec_h264.dylib" ] || MISS="$MISS 解码插件"
[ -f "$SRC/libnvencvt.dylib" ] || MISS="$MISS 编码插件"
[ -z "$MISS" ] || die "包里缺文件：${MISS}（压缩包不完整？）"

if [ "$1" = "--check" ]; then
    echo "插件目录：$B"
    for f in libnvdec_h264.dylib libnvencvt.dylib; do
        if [ ! -f "$B/$f" ]; then echo "  ${f}：不存在"
        elif is_ours "$B/$f"; then echo "  ${f}：已安装（我们的版本 $(our_version "$B/$f")）"
        else echo "  ${f}：已存在，是原厂版本"; fi
    done
    [ -f "$B/libnvdec_h264.dylib.vendor" ] && echo "  原厂解码插件备份：有"
    echo "配置：$CONF"
    if [ -f "$CONF" ]; then
        grep -E "^(NVMTL_NO_NVDEC|NVMTL_NVENCVT)=" "$CONF" 2>/dev/null | sed 's/^/  /'
        [ -n "$(conf_get NVMTL_NO_NVDEC)" ] && echo "  -> NVMTL_NO_NVDEC 存在：解码插件被停用"
        [ "$(conf_get NVMTL_NVENCVT)" = "0" ] && echo "  -> NVMTL_NVENCVT=0：编码插件不加载"
    else
        echo "  （不存在）"
    fi
    echo "体检结束，没有改动任何文件。"
    exit 0
fi

[ "$(id -u)" = 0 ] || [ -n "$NVCODEC_NO_ROOT_CHECK" ] || die "要 root：sudo ./install.sh"

# ---- 1) 备份原厂解码插件 ----
# 规则：备份只在“不存在”时创建，之后永不覆盖。
#   - 早期版本在每次安装都无条件备份，把唯一一份原厂文件覆盖成了我们自己的（踩过的坑）；
#   - 现在插件里有 nvcodec-blk-1401 标记，理论上能分辨，但旧版本插件没有这个标记，
#     所以宁可不刷新备份，也不能冒险覆盖。
if [ -f "$B/libnvdec_h264.dylib.vendor" ]; then
    info "原厂备份已存在，保留不动"
elif [ -f "$B/libnvdec_h264.dylib" ] && ! is_ours "$B/libnvdec_h264.dylib"; then
    cp -p "$B/libnvdec_h264.dylib" "$B/libnvdec_h264.dylib.vendor"
    info "已备份原厂解码插件 -> libnvdec_h264.dylib.vendor"
else
    info "没有原厂备份可用（本机一直是覆盖安装）。卸载时会改用配置开关回退。"
fi

# ---- 2) 覆盖安装（覆盖已有文件是允许的；在 SIP restricted 目录里新建文件可能被拒） ----
for f in libnvdec_h264.dylib libnvencvt.dylib; do
    if ! cp -f "$SRC/$f" "$B/$f" 2>/dev/null; then
        if [ "$f" = "libnvencvt.dylib" ]; then
            info "警告：编码插件写不进去（该目录禁止新建文件）。解码插件不受影响；"
            info "      要编码插件请改用同版本的 .pkg 安装包（安装器有权限）。"
            continue
        fi
        die "写不进 $B/${f}（目录受 SIP 保护，需要安装器权限；请改用 .pkg）"
    fi
    chmod 755 "$B/$f"
    chown root:wheel "$B/$f" 2>/dev/null || true
    codesign -f -s - "$B/$f" >/dev/null 2>&1 || true
    info "已安装 $f"
done

# ---- 3) 打开编码插件开关、去掉解码停用标记 ----
if [ -f "$CONF" ]; then
    [ -f "$CONF.orig" ] || cp -p "$CONF" "$CONF.orig"
    KEEP=$(grep -vE '^(NVMTL_NVENCVT|NVMTL_NO_NVDEC)=' "$CONF" || true)
    printf '%s\nNVMTL_NVENCVT=1\n' "$KEEP" > "$CONF"
    chown root:wheel "$CONF" 2>/dev/null || true
    chmod 644 "$CONF" 2>/dev/null || true
    info "配置已更新 ${CONF}（NVMTL_NVENCVT=1）"
else
    info "没有 ${CONF}（驱动版本不同？）：编码插件不会被加载，解码插件照常工作。"
fi

# ---- 4) 让 VideoToolbox 重新加载插件 ----
killall VTDecoderXPCService 2>/dev/null || true
killall VTEncoderXPCService 2>/dev/null || true

echo
echo "装好了。"
echo "  验证：用 NVCodecTest 或任何播放器解一段 H.264，应比软解快；"
echo "        强制硬件时“解码”显示 硬解通过，“编码”里出现 -H.264- / -HEVC- 的 NVIDIA 编码器。"
echo "  回退：sudo ./uninstall.sh"
