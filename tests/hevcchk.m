// hevcchk.m — 验证“系统 HEVC 硬编”是不是真的在编 HEVC：编 60 帧再解回来，逐帧比亮度 PSNR。
//   ./hevcchk [h264|hevc] [frames]
// PSNR 在 30 dB 以上说明码流能解回原来的画面；花屏/全黑会掉到 20 dB 以下。
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <math.h>

static const int W = 1920, H = 1080;

static CVPixelBufferRef makeFrame(int i) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)a, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int r = 0; r < H; r++)
        for (int c = 0; c < W; c++)
            y[r * ys + c] = (uint8_t)(((c * 255 / W) ^ (r * 3) ^ (i * 7)) & 0xff);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * H / 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

typedef struct { NSMutableArray *samples; CMVideoFormatDescriptionRef fmt; } EncOut;
static void encCb(void *rc, void *src, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
    (void)src; (void)f;
    if (st != noErr || !sb) return;
    EncOut *o = (EncOut *)rc;
    if (!o->fmt) o->fmt = (CMVideoFormatDescriptionRef)CFRetain(CMSampleBufferGetFormatDescription(sb));
    [o->samples addObject:(__bridge id)sb];
}

typedef struct { NSMutableArray *out; } DecOut;
static void decCb(void *rc, void *src, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime p, CMTime d) {
    (void)src; (void)f; (void)p; (void)d;
    DecOut *o = (DecOut *)rc;
    if (st == noErr && img) [o->out addObject:(__bridge id)img];
}

static double psnr(const CVPixelBufferRef a, const CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), *pb = CVPixelBufferGetBaseAddressOfPlane(b, 0);
    const size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const size_t w = CVPixelBufferGetWidthOfPlane(a, 0), h = CVPixelBufferGetHeightOfPlane(a, 0);
    double se = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) { const double d = (double)pa[y * sa + x] - (double)pb[y * sb + x]; se += d * d; }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const double mse = se / (double)(w * h);
    return mse <= 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 / mse);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const BOOL hevc = argc > 1 && !strcmp(argv[1], "hevc");
        const int N = argc > 2 ? atoi(argv[2]) : 60;
        (void)[[MTLCreateSystemDefaultDevice() name] UTF8String];

        EncOut eo = { [NSMutableArray array], NULL };
        NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES};
        VTCompressionSessionRef es = NULL;
        OSStatus st = VTCompressionSessionCreate(NULL, W, H, hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                 (__bridge CFDictionaryRef)spec, NULL, NULL, encCb, &eo, &es);
        if (st != noErr) { printf("压缩会话创建失败 %d\n", (int)st); return 1; }
        CFTypeRef encID = NULL;
        VTSessionCopyProperty(es, kVTCompressionPropertyKey_EncoderID, NULL, &encID);
        int32_t br = 8 * 1000 * 1000;
        CFNumberRef brRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &br);
        VTSessionSetProperty(es, kVTCompressionPropertyKey_AverageBitRate, brRef);
        VTSessionSetProperty(es, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        CFRelease(brRef);
        printf("编码器: %s\n", encID ? [(__bridge NSString *)encID UTF8String] : "(未报告)");
        if (encID) CFRelease(encID);

        const double t0 = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < N; i++) {
            CVPixelBufferRef pb = makeFrame(i);
            VTCompressionSessionEncodeFrame(es, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
            CVPixelBufferRelease(pb);
        }
        VTCompressionSessionCompleteFrames(es, kCMTimeInvalid);
        const double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("编码 %zu 帧, %.1f fps\n", (size_t)eo.samples.count, eo.samples.count / dt);
        VTCompressionSessionInvalidate(es); CFRelease(es);
        if (!eo.fmt || eo.samples.count == 0) return 1;

        const FourCharCode sub = CMFormatDescriptionGetMediaSubType(eo.fmt);
        printf("码流类型: '%c%c%c%c'", (char)(sub >> 24), (char)(sub >> 16), (char)(sub >> 8), (char)sub);
        if (sub == 'hvc1' || sub == 'hev1') {
            size_t n = 0;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(eo.fmt, 0, NULL, NULL, &n, NULL) == noErr)
                printf(", 参数集 %zu 个（HEVC 应为 VPS/SPS/PPS 3 个）", n);
        }
        printf("\n");

        NSDictionary *dst = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                              (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        DecOut dobj = { [NSMutableArray array] };
        VTDecompressionSessionRef ds = NULL;
        VTDecompressionOutputCallbackRecord cb = { decCb, &dobj };
        st = VTDecompressionSessionCreate(NULL, eo.fmt, NULL, (__bridge CFDictionaryRef)dst, &cb, &ds);
        if (st != noErr) { printf("解码会话创建失败 %d（码流可能不是合法 %s）\n", (int)st, hevc ? "HEVC" : "H.264"); return 1; }
        for (id o in eo.samples) VTDecompressionSessionDecodeFrame(ds, (__bridge CMSampleBufferRef)o, 0, NULL, NULL);
        VTDecompressionSessionWaitForAsynchronousFrames(ds);
        printf("解回 %zu / %zu 帧\n", dobj.out.count, eo.samples.count);

        double sum = 0, lo = 99;
        for (size_t i = 0; i < dobj.out.count; i++) {
            CVPixelBufferRef src = makeFrame((int)i);   // 编码输入是同一批图案帧，顺序一致（无 B 帧重排）
            const double p = psnr(src, (__bridge CVPixelBufferRef)dobj.out[i]);
            CVPixelBufferRelease(src);
            sum += p;
            if (p < lo) lo = p;
        }
        if (dobj.out.count) printf("亮度 PSNR: 平均 %.1f dB, 最低 %.1f dB %s\n", sum / dobj.out.count, lo,
                                   lo > 30 ? "-> 码流真实可解" : "-> 画面有问题");
        VTDecompressionSessionInvalidate(ds); CFRelease(ds);
        CFRelease(eo.fmt);
    }
    return 0;
}
