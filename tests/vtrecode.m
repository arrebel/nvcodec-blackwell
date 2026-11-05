// vtrecode.m — 用 VideoToolbox 编码一段真实视频，再把结果解码回来与原始帧比对，验证编码器输出正确。
//
//   vtrecode <in.mov> <out.mov> [maxFrames] [Mbps]
//
// 编码走系统的 H.264 编码器（装上我们的插件后就是 NVENC）；比对时两边都用 AVAssetReader 的 NV12 输出，
// 逐帧算亮度 PSNR。硬件编码是有损的，正常结果在 38-48 dB 之间；错位或花屏会掉到 20 dB 以下。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>
#include <stdlib.h>

typedef struct { VTCompressionSessionRef s; AVAssetWriter *w; AVAssetWriterInput *in; int n; } Enc;

static void enc_cb(void *out, void *src, OSStatus st, VTEncodeInfoFlags info, CMSampleBufferRef sb)
{
    Enc *e = (Enc *)out;
    (void)src; (void)info;
    if (st != noErr || !sb) { fprintf(stderr, "encode cb status %d\n", (int)st); return; }
    if (e->in.readyForMoreMediaData) {
        if (![e->in appendSampleBuffer:sb]) fprintf(stderr, "append 失败: %s\n", e->w.error.localizedDescription.UTF8String);
        else e->n++;
    }
}

// 逐帧亮度 PSNR
static double psnr_luma(CVPixelBufferRef a, CVPixelBufferRef b)
{
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), *pb = CVPixelBufferGetBaseAddressOfPlane(b, 0);
    const size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    const size_t w = CVPixelBufferGetWidthOfPlane(a, 0), h = CVPixelBufferGetHeightOfPlane(a, 0);
    double se = 0;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { const double d = (double)pa[y * sa + x] - (double)pb[y * sb + x]; se += d * d; }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const double mse = se / (double)(w * h);
    return mse <= 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 / mse);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: vtrecode in.mov out.mov [maxFrames] [Mbps]\n"); return 2; }
        NSString *inPath = @(argv[1]), *outPath = @(argv[2]);
        const int maxFrames = argc > 3 ? atoi(argv[3]) : 120;
        const double mbps = argc > 4 ? atof(argv[4]) : 12.0;
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

        // ---- 源 ----
        NSURL *inURL = [NSURL fileURLWithPath:inPath];
        AVAsset *asset = [AVAsset assetWithURL:inURL];
        AVAssetTrack *vtrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!vtrack) { printf("没有视频轨\n"); return 1; }
        const CGSize size = vtrack.naturalSize;
        const int W = (int)size.width, H = (int)size.height;

        NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };

        // ---- 编码器 ----
        Enc e = { 0 };
        CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                             getenv("VTRECODE_SW") ? kCFBooleanFalse : kCFBooleanTrue);
        OSStatus st = VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, spec, NULL, NULL, enc_cb, &e, &e.s);
        CFRelease(spec);
        if (st != noErr) { printf("VTCompressionSessionCreate -> %d\n", (int)st); return 1; }
        int32_t br = (int32_t)(mbps * 1e6);
        CFNumberRef brRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &br);
        VTSessionSetProperty(e.s, kVTCompressionPropertyKey_AverageBitRate, brRef); CFRelease(brRef);
        VTSessionSetProperty(e.s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(e.s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(e.s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
        VTCompressionSessionPrepareToEncodeFrames(e.s);

        // ---- 写出 ----
        NSError *err = nil;
        e.w = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outPath] fileType:AVFileTypeQuickTimeMovie error:&err];
        if (!e.w) { printf("writer: %s\n", err.localizedDescription.UTF8String); return 1; }
        // 直通：只写编码器给出的样本（带 outputSettings 的输入要求喂原始帧）
        e.in = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil];
        e.in.expectsMediaDataInRealTime = NO;
        [e.w addInput:e.in];
        [e.w startWriting];
        [e.w startSessionAtSourceTime:kCMTimeZero];

        AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&err];
        AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:vtrack outputSettings:settings];
        [rd addOutput:out];
        [rd startReading];

        const double t0 = CFAbsoluteTimeGetCurrent();
        int fed = 0;
        while (fed < maxFrames) {
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (!sb) break;
            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
            VTEncodeInfoFlags fl = 0;
            OSStatus r = VTCompressionSessionEncodeFrame(e.s, pb, pts, CMTimeMake(1, 30), NULL, NULL, &fl);
            if (r != noErr) { printf("encode -> %d\n", (int)r); CFRelease(sb); break; }
            CFRelease(sb);
            fed++;
        }
        VTCompressionSessionCompleteFrames(e.s, kCMTimeInvalid);
        const double dt = CFAbsoluteTimeGetCurrent() - t0;
        [e.in markAsFinished];
        [e.w endSessionAtSourceTime:CMTimeMake(fed, 30)];
        [e.w finishWriting];

        // ---- 解码回来比对 ----
        AVAsset *enc = [AVAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
        AVAssetReader *rd2 = [AVAssetReader assetReaderWithAsset:enc error:&err];
        AVAssetReaderTrackOutput *out2 = [[AVAssetReaderTrackOutput alloc] initWithTrack:[enc tracksWithMediaType:AVMediaTypeVideo].firstObject
                                                                        outputSettings:settings];
        [rd2 addOutput:out2];
        [rd2 startReading];

        double worst = 99, sum = 0; int n = 0, mism = 0;
        // 源要重新开一个读取器：编码时那个已经被读掉了 fed 帧，继续读就是拿后面的帧和编码的第 0 帧比
        AVAssetReader *rd3 = [AVAssetReader assetReaderWithAsset:asset error:&err];
        AVAssetReaderTrackOutput *src = [[AVAssetReaderTrackOutput alloc] initWithTrack:vtrack outputSettings:settings];
        [rd3 addOutput:src];
        [rd3 startReading];
        while (n < fed) {
            CMSampleBufferRef s1 = [src copyNextSampleBuffer];
            CMSampleBufferRef s2 = [out2 copyNextSampleBuffer];
            if (!s1 || !s2) { if (s1) CFRelease(s1); if (s2) CFRelease(s2); break; }
            const double p = psnr_luma(CMSampleBufferGetImageBuffer(s1), CMSampleBufferGetImageBuffer(s2));
            if (p < worst) worst = p;
            if (p < 30) mism++;
            sum += p; n++;
            CFRelease(s1); CFRelease(s2);
        }
        printf("%s %dx%d: 编码 %d 帧 %.0f fps (%.2f ms/帧), 回读 %d 帧, 亮度 PSNR 平均 %.2f dB 最差 %.2f dB, 低于 30 dB 的 %d 帧\n",
               inPath.lastPathComponent.UTF8String, W, H, fed, fed / dt, dt * 1000 / (fed ? fed : 1), n, n ? sum / n : 0, worst, mism);
        VTCompressionSessionInvalidate(e.s); CFRelease(e.s);
        return mism ? 1 : 0;
    }
}
