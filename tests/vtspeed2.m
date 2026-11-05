// vtspeed2.m — 播放器式压测：AVAssetReader + outputSettings(NV12) 让 VideoToolbox 真解码，
// 只统计"拿到多少帧"，不碰 CGImage，避免把转码开销算进来。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

static double cpuSeconds(void) {
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_stime.tv_sec + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: vtspeed2 file.mov [maxFrames] [threads:0=serial]\n"); return 2; }
        NSString *p = [NSString stringWithUTF8String:argv[1]];
        int maxF = argc > 2 ? atoi(argv[2]) : 100000;
        int threads = argc > 3 ? atoi(argv[3]) : 0;

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:p] options:nil];
        AVAssetTrack *tr = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!tr) { printf("没有视频轨\n"); return 1; }
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)tr.formatDescriptions.firstObject;
        FourCharCode c = CMFormatDescriptionGetMediaSubType(fd);
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fd);

        NSError *e = nil;
        AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&e];
        // VTS_NATIVE=1: no pixel format conversion (the decoder's own output), i.e. what a player gets
        NSDictionary *settings = getenv("VTS_NATIVE") ? nil :
            @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        // VTS_SEEK=<seconds>: start there, which makes VideoToolbox open a new session at a keyframe
        if (getenv("VTS_SEEK")) {
            const double t = atof(getenv("VTS_SEEK"));
            rd.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(t, 600), CMTimeMakeWithSeconds(4.0, 600));
        }
        AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:settings];
        out.alwaysCopiesSampleData = NO;
        [rd addOutput:out];
        if (![rd startReading]) { printf("读取启动失败: %s\n", rd.error.localizedDescription.UTF8String); return 1; }

        double c0 = cpuSeconds(), t0 = CFAbsoluteTimeGetCurrent();
        long n = 0;
        while (n < maxF) {
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (!sb) break;
            CFRelease(sb);
            n++;
        }
        double wall = CFAbsoluteTimeGetCurrent() - t0, cpu = cpuSeconds() - c0;
        printf("%-14s %dx%d '%c%c%c%c': %ld 帧, %.1f fps, CPU %5.1f%% (%.2fs CPU/%.2fs 墙钟), 状态 %ld\n",
               p.lastPathComponent.UTF8String, dim.width, dim.height,
               (char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c,
               n, n / wall, 100.0 * cpu / wall, cpu, wall, (long)rd.status);
    }
    return 0;
}
