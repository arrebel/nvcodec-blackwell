// vtimg.m — 用 AVAssetImageGenerator 走完整 AVFoundation→VideoToolbox 解码链路，
// 统计解码耗时；同时对比 AVAssetReader 输出。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: vtimg file.mov\n"); return 2; }
        NSString *p = [NSString stringWithUTF8String:argv[1]];
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:p] options:nil];
        NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
        if (!tracks.count) { printf("没有视频轨\n"); return 1; }
        AVAssetTrack *t = tracks.firstObject;
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)t.formatDescriptions.firstObject;
        FourCharCode c = fd ? CMFormatDescriptionGetMediaSubType(fd) : 0;
        printf("%s: %dx%d codec '%c%c%c%c' 时长 %.2fs\n", p.lastPathComponent.UTF8String,
               (int)t.naturalSize.width, (int)t.naturalSize.height,
               (char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c, CMTimeGetSeconds(a.duration));

        AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
        g.requestedTimeToleranceBefore = kCMTimeZero;
        g.requestedTimeToleranceAfter = kCMTimeZero;
        double t0 = CFAbsoluteTimeGetCurrent();
        int ok = 0, fail = 0;
        for (int i = 0; i < 20; i++) {
            CMTime at = CMTimeMakeWithSeconds(i * 0.05, 600);
            NSError *e = nil;
            CGImageRef img = [g copyCGImageAtTime:at actualTime:NULL error:&e];
            if (img) { ok++; CGImageRelease(img); }
            else { fail++; if (fail == 1) printf("  失败: %s\n", e.localizedDescription.UTF8String); }
        }
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
        printf("  取帧 %d 成功 / %d 失败，共 %.1f ms\n", ok, fail, ms);
    }
    return 0;
}
