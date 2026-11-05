// vtprops3.m — 自己造码流（VT 软编）再开一个“强制硬件”解码会话，问插件它是不是硬件、属于哪块 GPU，
// 然后解完整条流测速。不依赖 AVAssetReader（它的输出已经是解码后的像素，会话会以 -12916 拒绝）。
//   ./vtprops3 [plugin.dylib]
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>

static const int W = 1920, H = 1080, NFRAMES = 120;

typedef int32_t (*VTRegisterFn)(CFStringRef, CFDictionaryRef, void *);
static void registerPlugin(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen %s: %s\n", path, dlerror()); return; }
    void *create = dlsym(h, "NVDecH264_CreateInstance");
    VTRegisterFn reg = (VTRegisterFn)dlsym(RTLD_DEFAULT, "VTRegisterVideoDecoderWithInfo");
    if (!create || !reg) { printf("注册失败（缺符号）\n"); return; }
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
    int rating = 5000;
    CFNumberRef r = CFNumberCreate(NULL, kCFNumberIntType, &rating);
    CFDictionarySetValue(info, CFSTR("VTRating"), r);
    CFDictionarySetValue(info, CFSTR("VTIsHardwareAccelerated"), kCFBooleanTrue);
    CFDictionarySetValue(info, CFSTR("CMClassImplementationID"), CFSTR("com.nvmtl.nvdec.avc"));
    printf("register -> %d\n", (int)reg(CFSTR("com.nvmtl.videodecoder.avc.nvdec"), info, create));
    CFRelease(r); CFRelease(info);
}

static CVPixelBufferRef makeFrame(int i) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int r = 0; r < H; r++)
        for (int c = 0; c < W; c++)
            y[r * ys + c] = (uint8_t)(((c >> 2) + (r >> 2) + i * 2) & 0xff);
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

static NSString *describe(VTSessionRef s, CFStringRef key, OSStatus *o) {
    CFTypeRef v = NULL;
    OSStatus st = VTSessionCopyProperty(s, key, NULL, &v);
    if (o) *o = st;
    if (st != noErr || !v) { if (v) CFRelease(v); return nil; }
    NSString *r;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v) ? @"true" : @"false";
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        long long n = 0; CFNumberGetValue(v, kCFNumberSInt64Type, &n);
        r = [NSString stringWithFormat:@"%lld (0x%llx)", n, (unsigned long long)n];
    } else r = [(__bridge id)v description];
    CFRelease(v);
    return r;
}

static int gGot = 0;
static void onFrame(void *rc, void *src, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime d) {
    (void)rc; (void)src; (void)f; (void)pts; (void)d;
    if (st == noErr && img) gGot++;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1) registerPlugin(argv[1]);
        (void)[[MTLCreateSystemDefaultDevice() name] UTF8String];

        EncOut out = { [NSMutableArray array], NULL };
        NSDictionary *spec = @{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @NO};
        VTCompressionSessionRef es = NULL;
        if (VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec, NULL, NULL,
                                       encCb, &out, &es) != noErr) { printf("压缩会话创建失败\n"); return 1; }
        for (int i = 0; i < NFRAMES; i++) {
            CVPixelBufferRef pb = makeFrame(i);
            VTCompressionSessionEncodeFrame(es, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
            CVPixelBufferRelease(pb);
        }
        VTCompressionSessionCompleteFrames(es, kCMTimeInvalid);
        VTCompressionSessionInvalidate(es); CFRelease(es);
        printf("软编码流 %zu 帧 %dx%d\n", (size_t)out.samples.count, W, H);
        if (!out.fmt) return 1;

        NSDictionary *dspec = @{(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        NSDictionary *dst = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                              (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        VTDecompressionSessionRef s = NULL;
        VTDecompressionOutputCallbackRecord cb = { onFrame, NULL };
        OSStatus st = VTDecompressionSessionCreate(NULL, out.fmt, (__bridge CFDictionaryRef)dspec,
                                                   (__bridge CFDictionaryRef)dst, &cb, &s);
        printf("会话创建(强制硬件) -> %d\n", (int)st);
        if (st != noErr) return 1;

        OSStatus s1 = 0, s2 = 0;
        NSString *hw = describe((VTSessionRef)s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, &s1);
        NSString *gpu = describe((VTSessionRef)s, kVTDecompressionPropertyKey_UsingGPURegistryID, &s2);
        printf("UsingHardwareAcceleratedVideoDecoder = %s (OSStatus %d)\n", hw ? hw.UTF8String : "nil", (int)s1);
        printf("UsingGPURegistryID                  = %s (OSStatus %d)\n", gpu ? gpu.UTF8String : "nil", (int)s2);
        if (gpu) {
            long long rid = [[gpu componentsSeparatedByString:@" "].firstObject longLongValue];
            io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching((uint64_t)rid));
            if (svc) {
                io_name_t cls; IOObjectGetClass(svc, cls);
                CFTypeRef ven = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, CFSTR("vendor-id"), NULL,
                    kIORegistryIterateRecursively | kIORegistryIterateParents);
                unsigned v = 0;
                if (ven && CFGetTypeID(ven) == CFDataGetTypeID() && CFDataGetLength(ven) >= 2)
                    CFDataGetBytes(ven, CFRangeMake(0, 2), (UInt8 *)&v);
                if (ven) CFRelease(ven);
                printf("  反查：IOClass=%s vendor-id=0x%04x%s\n", cls, v, v == 0x10de ? " -> NVIDIA" : " -> 不是 NVIDIA");
                IOObjectRelease(svc);
            } else printf("  反查：没有对应服务\n");
        }

        const double t0 = CFAbsoluteTimeGetCurrent();
        int n = 0;
        for (id o in out.samples) {
            CMSampleBufferRef sb = (__bridge CMSampleBufferRef)o;
            VTDecodeInfoFlags info = 0;
            OSStatus e = VTDecompressionSessionDecodeFrame(s, sb, 0, &info, NULL);
            if (e != noErr) { printf("第 %d 帧提交失败 %d\n", n, (int)e); break; }
            n++;
        }
        VTDecompressionSessionWaitForAsynchronousFrames(s);
        const double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        printf("提交 %d 帧, %.1f ms, %.1f fps, 输出 %d 帧\n", n, ms, n / (ms / 1000.0), gGot);
        VTDecompressionSessionInvalidate(s); CFRelease(s);
        CFRelease(out.fmt);
    }
    return 0;
}
