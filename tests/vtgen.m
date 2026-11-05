// vtgen.m — 造一段可解码的真实片子：1080p60，NVENC 编码，高熵画面（噪声+渐变），
// 这样解码不是"一片纯色"的作弊情况。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

static int gW, gH;
static uint32_t gSeed = 12345;
static inline uint32_t rnd(void) { gSeed = gSeed * 1664525u + 1013904223u; return gSeed >> 8; }

static CVPixelBufferRef frame(int i) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *a = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    CVPixelBufferCreate(NULL, gW, gH, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    BOOL noise = getenv("VTGEN_NOISE") != NULL;   // 静态高熵噪声：位置可唯一识别，用于反推布局
    for (int r = 0; r < gH; r++) {
        for (int c = 0; c < gW; c++) {
            if (noise) {
                uint32_t h = (uint32_t)(c * 2654435761u ^ r * 40503u);
                h ^= h >> 13; h *= 1274126177u; h ^= h >> 16;
                y[r * ys + c] = (uint8_t)(h & 0xff);
            } else {
                int v = ((c * 3 + r * 2 + i * 7) & 0x7f) + ((c >> 4) ^ (r >> 4)) + 40;
                if (((c + i * 3) % 97) < 6) v += (int)(rnd() & 63);    // 局部高频，制造真实码率
                y[r * ys + c] = (uint8_t)(v & 0xff);
            }
        }
    }
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < gH / 2; r++)
        for (int c = 0; c < gW; c += 2) {
            if (noise) {
                uint32_t h = (uint32_t)((c + 1) * 2246822519u ^ (r + 7) * 3266489917u);
                h ^= h >> 15; h *= 2654435761u; h ^= h >> 13;
                uv[r * uvs + c] = (uint8_t)(h & 0xff);
                uv[r * uvs + c + 1] = (uint8_t)((h >> 8) & 0xff);
            } else {
                uv[r * uvs + c] = (uint8_t)(80 + ((c + i) & 0x3f));
                uv[r * uvs + c + 1] = (uint8_t)(160 - ((r + i) & 0x3f));
            }
        }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 6) { printf("usage: vtgen out.mov <h264|hevc> width height frames [bitrateMbps]\n"); return 2; }
        NSString *out = [NSString stringWithUTF8String:argv[1]];
        BOOL hevc = strcmp(argv[2], "hevc") == 0;
        gW = atoi(argv[3]); gH = atoi(argv[4]);
        int n = atoi(argv[5]);
        int mbps = argc > 6 ? atoi(argv[6]) : (gW >= 3000 ? 25 : 12);
        [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
        NSError *e = nil;
        AVAssetWriter *aw = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:out] fileType:AVFileTypeMPEG4 error:&e];
        NSDictionary *s = @{AVVideoCodecKey: hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
                            AVVideoWidthKey: @(gW), AVVideoHeightKey: @(gH),
                            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(mbps * 1000000),
                                                              AVVideoExpectedSourceFrameRateKey: @60,
                                                              AVVideoMaxKeyFrameIntervalKey: @60}};
        AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:s];
        in.expectsMediaDataInRealTime = NO;
        AVAssetWriterInputPixelBufferAdaptor *ad =
            [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in sourcePixelBufferAttributes:nil];
        [aw addInput:in];
        if (![aw startWriting]) { printf("startWriting 失败: %s\n", aw.error.localizedDescription.UTF8String); return 1; }
        [aw startSessionAtSourceTime:kCMTimeZero];
        double t0 = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < n; i++) {
            while (!in.isReadyForMoreMediaData) usleep(1000);
            CVPixelBufferRef pb = frame(i);
            [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(i, 60)];
            CVPixelBufferRelease(pb);
        }
        [in markAsFinished];
        __block BOOL ok = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [aw finishWritingWithCompletionHandler:^{ ok = (aw.status == AVAssetWriterStatusCompleted); dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:out error:nil];
        printf("生成 %s: %dx%d %d 帧, %s, %.2f MB, 编码 %.1f fps\n", out.lastPathComponent.UTF8String, gW, gH, n,
               ok ? "成功" : aw.error.localizedDescription.UTF8String,
               [at[NSFileSize] doubleValue] / 1048576.0, ok ? n / dt : 0);
    }
    return 0;
}
