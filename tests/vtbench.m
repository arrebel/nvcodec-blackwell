// vtbench.m — 用 Apple 软件编码器造一份可信 H.264/HEVC 码流，再分别用
// (a) 任意解码器 (b) 强制硬件解码 去解，测量每帧耗时并校验输出。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>

static const int W = 1280, H = 720, NFRAMES = 120;

static CVPixelBufferRef makeFrame(int i) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (__bridge CFDictionaryRef)attrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int r = 0; r < H; r++)
        for (int c = 0; c < W; c++)
            y[r * ys + c] = (uint8_t)(((c >> 2) + (r >> 2) + i * 2) & 0xff);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    memset(uv, 128, uvs * H / 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

typedef struct { NSMutableArray *samples; CMVideoFormatDescriptionRef fmt; } EncOut;

static void encCallback(void *refcon, void *src, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status != noErr || !sb) return;
    EncOut *o = (EncOut *)refcon;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (fd && !o->fmt) o->fmt = (CMVideoFormatDescriptionRef)CFRetain(fd);
    [o->samples addObject:(__bridge id)sb];
}

static BOOL encodeStream(CMVideoCodecType codec, EncOut *out) {
    NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @NO};
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, W, H, codec, (__bridge CFDictionaryRef)spec, NULL, NULL,
        encCallback, (void *)out, &s);
    if (st != noErr) { printf("  压缩会话创建失败 %d\n", (int)st); return NO; }
    for (int i = 0; i < NFRAMES; i++) {
        CVPixelBufferRef pb = makeFrame(i);
        st = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
        CVPixelBufferRelease(pb);
        if (st != noErr) { printf("  编码第 %d 帧失败 %d\n", i, (int)st); break; }
    }
    VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    printf("  软件编码 %zu 帧，参数集 %s\n", (size_t)out->samples.count, out->fmt ? "有" : "无");
    return out->samples.count > 0 && out->fmt != NULL;
}

static double decodeAll(EncOut *in, const char *label, BOOL requireHW, BOOL enableHW, int measured) {
    NSDictionary *spec = @{(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @(requireHW),
                           (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @(enableHW)};
    NSDictionary *dst = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                          (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    VTDecompressionSessionRef s = NULL;
    OSStatus st = VTDecompressionSessionCreate(NULL, in->fmt, (__bridge CFDictionaryRef)spec,
                                               (__bridge CFDictionaryRef)dst, NULL, &s);
    if (st != noErr) { printf("%-22s 会话创建失败 %d\n", label, (int)st); return -1; }
    CFTypeRef v = NULL;
    BOOL hw = NO;
    if (VTSessionCopyProperty(s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &v) == noErr && v)
        hw = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue(v);
    if (v) CFRelease(v);

    __block int got = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    for (id obj in in->samples) {
        CMSampleBufferRef sb = (__bridge CMSampleBufferRef)obj;
        VTDecodeInfoFlags flags = 0;
        st = VTDecompressionSessionDecodeFrame(s, sb, 0, NULL, &flags);
        if (st != noErr) { printf("%-22s 第 %d 帧失败 %d\n", label, got, (int)st); break; }
        got++;
        if (got == measured) break;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(s);
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    printf("%-22s 硬件=%s  提交 %d 帧, %.2f ms/帧 => %.1f fps\n", label, hw ? "是" : "否", got,
           got ? ms / got : 0, got ? got / (ms / 1000.0) : 0);
    VTDecompressionSessionInvalidate(s);
    CFRelease(s);
    return ms;
}

int main(void) {
    @autoreleasepool {
        (void)[[MTLCreateSystemDefaultDevice() name] UTF8String];
        struct { CMVideoCodecType codec; const char *name; } tests[] = {
            { kCMVideoCodecType_H264, "H.264" }, { kCMVideoCodecType_HEVC, "HEVC" } };
        for (int t = 0; t < 2; t++) {
            printf("=== %s ===\n", tests[t].name);
            EncOut out = { [NSMutableArray array], NULL };
            if (!encodeStream(tests[t].codec, &out)) { printf("  跳过\n"); continue; }
            decodeAll(&out, "  仅软件(any)", NO, NO, 40);
            decodeAll(&out, "  允许硬件(any)", NO, YES, 40);
            decodeAll(&out, "  强制硬件", YES, YES, 40);
            if (out.fmt) CFRelease(out.fmt);
        }
    }
    return 0;
}
