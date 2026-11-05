// vtenc.m — VideoToolbox 编码测速：判断当前用的是硬件编码器还是苹果的软件编码器。
//
//   vtenc <h264|hevc> <w> <h> <frames> [Mbps]
//
// VTE_SW=1 强制软件编码（EnableHardwareAcceleratedVideoEncoder=NO）作为基线。
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <stdlib.h>

static int gFrames = 0, gErrors = 0;

static double now(void) { return CFAbsoluteTimeGetCurrent(); }

static void enc_cb(void *out, void *src, OSStatus st, VTEncodeInfoFlags info, CMSampleBufferRef sb)
{
    (void)out; (void)src;
    if (st != noErr) gErrors++;
    if (sb) gFrames++;
    if (info & kVTEncodeInfo_FrameDropped) gErrors++;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 5) { fprintf(stderr, "usage: vtenc <h264|hevc> <w> <h> <frames> [Mbps]\n"); return 2; }
        const BOOL hevc = !strcmp(argv[1], "hevc");
        const int W = atoi(argv[2]), H = atoi(argv[3]), N = atoi(argv[4]);
        const double mbps = argc > 5 ? atof(argv[5]) : 8.0;
        const BOOL forceSw = getenv("VTE_SW") != NULL;

        // VTE_METAL=1：先建一个 Metal 设备。NVMTL 的驱动插件（含 NVENC 编码器）是在 Metal 设备创建时加载的，
        // 不建设备的话纯 VideoToolbox 进程里根本不会加载它——这里用来验证真实加载路径。
        if (getenv("VTE_METAL")) {
            id<MTLDevice> d = MTLCreateSystemDefaultDevice();
            printf("metal: %s\n", d ? d.name.UTF8String : "(none)");
        }
        CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                             forceSw ? kCFBooleanFalse : kCFBooleanTrue);

        VTCompressionSessionRef s = NULL;
        OSStatus st = VTCompressionSessionCreate(NULL, W, H, hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                spec, NULL, NULL, enc_cb, NULL, &s);
        CFRelease(spec);
        if (st != noErr) { printf("VTCompressionSessionCreate -> %d\n", (int)st); return 1; }

        int32_t br = (int32_t)(mbps * 1000 * 1000);
        CFNumberRef brRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &br);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, brRef);
        CFRelease(brRef);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel,
                             hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel);
        VTCompressionSessionPrepareToEncodeFrames(s);

        CVPixelBufferRef pb = NULL;
        NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &pb);
        if (!pb) { printf("pixel buffer 创建失败\n"); return 1; }
        CVPixelBufferLockBaseAddress(pb, 0);
        {
            uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
            const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
            const size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            for (int r = 0; r < H; r++) for (int x = 0; x < W; x++) y[r * ys + x] = (uint8_t)((x * 255 / W + r * 3) & 0xff);
            for (int r = 0; r < H / 2; r++) for (int x = 0; x < W; x++) uv[r * uvs + x] = (uint8_t)((x * 7 + r * 13) & 0xff);
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);

        const double t0 = now();
        for (int i = 0; i < N; i++) {
            VTEncodeInfoFlags flags = 0;
            const OSStatus e = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, &flags);
            if (e != noErr) { printf("encode frame %d -> %d\n", i, (int)e); gErrors++; break; }
        }
        VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
        const double dt = now() - t0;

        printf("%-5s %dx%d %d 帧: %6.1f fps, 总耗时 %6.0f ms, 错误 %d\n",
               hevc ? "hevc" : "h264", W, H, gFrames, gFrames / dt, dt * 1000, gErrors);
        VTCompressionSessionInvalidate(s);
        CFRelease(s);
        CVPixelBufferRelease(pb);
        return 0;
    }
}
