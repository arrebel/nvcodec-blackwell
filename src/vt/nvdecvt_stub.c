// nvdecvt_stub.c — 解码器注册的占位实现。
//
// 上游把 H.264 / HEVC / AV1 解码器注册写在同一份 vt/nvencvt_dec.c 里，由 NVEncVT_Register 顺带调用。这里不启用它：
// H.264 解码走我们自己的 libnvdec_h264.dylib（src/vtdec.c，Blackwell 表面布局 + 快反平铺已实机验证），
// HEVC 解码继续用驱动自带的插件。保留这个符号只是让 NVEncVT_Register 能链接。
#include <VideoToolbox/VideoToolbox.h>

__attribute__((visibility("default"))) OSStatus NVDecVT_Register(int rating)
{
    (void)rating;
    return kVTCouldNotFindVideoDecoderErr;
}
