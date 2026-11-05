#!/bin/sh
# build.sh — H.264 VideoToolbox plugins for NVIDIA Blackwell on macOS.
#
#   ./fetch-vendor.sh     once: clones the NVIDIA headers the codec code needs
#   sh build.sh           the two plugins -> build/libnvdec_h264.dylib, build/libnvencvt.dylib
#   sh build.sh tools     the plugins and the test programs -> build/ (see tests/, tools/)
#   sh build.sh clean
set -e
cd "$(dirname "$0")"

VER=$(sed -n 's/^version=//p' VERSION 2>/dev/null | head -1)
[ -n "$VER" ] || VER=0.0.0

INC="$PWD/vendor"
KINC="$INC/open-gpu-kernel-modules/src/common/sdk/nvidia/inc"
UINC="$INC/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/include"
DOC="$INC/open-gpu-doc"

case "$1" in clean) rm -rf build; echo "cleaned"; exit 0 ;; esac

if [ ! -f "$DOC/classes/video/clc9b0.h" ] || [ ! -d "$KINC" ]; then
    echo "vendor headers missing: run ./fetch-vendor.sh first" >&2
    exit 1
fi

CFLAGS="-arch x86_64 -mmacosx-version-min=15.0 -O2 -w -DNVCODEC_VERSION=\"$VER\" \
 -I src -I $KINC -I $UINC -I $DOC/classes/video -I $DOC/classes"
FRAMEWORKS="-framework IOKit -framework CoreFoundation -framework CoreMedia -framework CoreVideo \
 -framework VideoToolbox -framework Accelerate"

mkdir -p build

# ---- decoder plugin: one exported symbol, everything else hidden ----
# All internal symbols used to be exported, and a process that loads the HEVC plugin next to ours then binds
# against whatever it finds first (that halved HEVC decode speed). Restrict the export list.
cat > build/exports.txt <<'EOF'
_NVDecH264_CreateInstance
EOF

xcrun clang $CFLAGS -fvisibility=hidden -dynamiclib \
    -install_name /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvdec_h264.dylib \
    src/rm.c src/channel.c src/blocklinear.c src/h264parse.c src/dec.c src/vtdec.c $FRAMEWORKS \
    -Wl,-exported_symbols_list,build/exports.txt \
    -o build/libnvdec_h264.dylib
codesign -f -s - build/libnvdec_h264.dylib >/dev/null 2>&1 || true
echo "==> build/libnvdec_h264.dylib    $(nm -gU build/libnvdec_h264.dylib | wc -l | tr -d ' ') exported symbol(s)"

# ---- encoder plugin: NVMTLDriver loads it when nvrm610.conf has NVMTL_NVENCVT=1 ----
cat > build/enc-exports.txt <<'EOF'
_NVEncVT_Register
_NVEncVT_CreateInstance
EOF

ENC_SRCS="$(ls src/*.c | grep -v -e vtdec.c)"
xcrun clang $CFLAGS -fvisibility=hidden -dynamiclib -I src/vt -DNVENC_VERSION='"0.9.5-bw"' \
    -install_name /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvencvt.dylib \
    src/vt/vtnvenc.c src/vt/nvdecvt_stub.c $ENC_SRCS $FRAMEWORKS -framework IOSurface \
    -Wl,-exported_symbols_list,build/enc-exports.txt \
    -o build/libnvencvt.dylib
codesign -f -s - build/libnvencvt.dylib >/dev/null 2>&1 || true
echo "==> build/libnvencvt.dylib       $(nm -gU build/libnvencvt.dylib | wc -l | tr -d ' ') exported symbol(s)"

[ "$1" = "tools" ] || exit 0

# ---- test programs (not part of what gets installed) ----
for t in decodeN hevcdecodeN encodeN; do
    [ -f tools/$t.c ] || continue
    xcrun clang $CFLAGS tools/$t.c $ENC_SRCS -framework IOKit -framework CoreFoundation -framework Accelerate \
        -o build/$t
done
for m in tests/*.m; do
    n=$(basename "$m" .m)
    xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -O2 -w \
        -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework CoreGraphics -framework VideoToolbox -framework IOSurface -framework Metal -framework IOKit \
        "$m" -o "build/$n"
done
echo "==> build/: $(ls build | tr '\n' ' ')"
