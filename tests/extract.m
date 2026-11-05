// extract.m — 从 .mov 里取出：① 第一段 Annex-B 码流（给 decode1 用）
// ② 第 0 帧的正确解码结果（NV12→I420，作为布局反推的基准）
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <arpa/inet.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { printf("usage: extract in.mov out.h264 ref.i420\n"); return 2; }
        NSString *p = [NSString stringWithUTF8String:argv[1]];
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:p] options:nil];
        AVAssetTrack *tr = [[a tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!tr) { printf("没有视频轨\n"); return 1; }
        NSError *e = nil;

        // ① 码流
        AVAssetReader *r1 = [AVAssetReader assetReaderWithAsset:a error:&e];
        AVAssetReaderTrackOutput *o1 = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:nil];
        [r1 addOutput:o1]; [r1 startReading];
        NSMutableData *bs = [NSMutableData data];
        CMFormatDescriptionRef fd0 = (__bridge CMFormatDescriptionRef)tr.formatDescriptions.firstObject;
        const int maxN = argc > 4 ? atoi(argv[4]) : 30;
        const BOOL hevc = fd0 && CMFormatDescriptionGetMediaSubType(fd0) == 'hvc1';
        // 参数集先写成 Annex-B
        size_t nps = 0;
        if (fd0) { if (hevc) CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd0, 0, NULL, NULL, &nps, NULL);
                   else CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd0, 0, NULL, NULL, &nps, NULL); }
        for (size_t i = 0; i < nps; i++) {
            const uint8_t *ps = NULL; size_t plen = 0;
            const OSStatus psr = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd0, i, &ps, &plen, NULL, NULL)
                                      : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd0, i, &ps, &plen, NULL, NULL);
            if (psr == noErr) {
                uint32_t sc = htonl(1);
                [bs appendBytes:&sc length:4];
                [bs appendBytes:ps length:plen];
            }
        }
        int got = 0;
        while (got < maxN) {
            CMSampleBufferRef sb = [o1 copyNextSampleBuffer];
            if (!sb) break;
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            size_t len = CMBlockBufferGetDataLength(bb);
            uint8_t *buf = malloc(len);
            CMBlockBufferCopyDataBytes(bb, 0, len, buf);
            size_t off = 0;
            while (off + 4 <= len) {          // AVCC 的 4 字节长度换成起始码
                uint32_t nal = ntohl(*(uint32_t *)(buf + off));
                off += 4;
                if (nal == 0 || off + nal > len) break;
                uint32_t sc = htonl(1);
                [bs appendBytes:&sc length:4];
                [bs appendBytes:buf + off length:nal];
                off += nal;
            }
            free(buf);
            CFRelease(sb);
            got++;
        }
        [bs writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:NO];
        printf("写码流 %d 个样本, %zu 字节\n", got, (size_t)bs.length);

        // ② 基准帧
        AVAssetReader *r2 = [AVAssetReader assetReaderWithAsset:a error:&e];
        NSDictionary *s = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        AVAssetReaderTrackOutput *o2 = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:s];
        [r2 addOutput:o2]; [r2 startReading];
        CMSampleBufferRef sb = [o2 copyNextSampleBuffer];
        if (!sb) { printf("取帧失败\n"); return 1; }
        CVImageBufferRef cv = CMSampleBufferGetImageBuffer(sb);
        CVPixelBufferLockBaseAddress(cv, kCVPixelBufferLock_ReadOnly);
        int W = (int)CVPixelBufferGetWidth(cv), H = (int)CVPixelBufferGetHeight(cv);
        const uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(cv, 0);
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(cv, 0);
        const uint8_t *UV = CVPixelBufferGetBaseAddressOfPlane(cv, 1);
        size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(cv, 1);
        NSMutableData *ref = [NSMutableData dataWithLength:(size_t)W * H * 3 / 2];
        uint8_t *rp = ref.mutableBytes;
        for (int r = 0; r < H; r++) memcpy(rp + (size_t)r * W, Y + (size_t)r * ys, W);
        uint8_t *U = rp + (size_t)W * H, *V = U + (size_t)W * H / 4;
        for (int r = 0; r < H / 2; r++)
            for (int c = 0; c < W / 2; c++) {
                U[(size_t)r * (W / 2) + c] = UV[(size_t)r * uvs + c * 2];
                V[(size_t)r * (W / 2) + c] = UV[(size_t)r * uvs + c * 2 + 1];
            }
        [ref writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:NO];
        printf("写基准帧 %dx%d (I420)\n", W, H);
        CVPixelBufferUnlockBaseAddress(cv, kCVPixelBufferLock_ReadOnly);
        CFRelease(sb);
    }
    return 0;
}
