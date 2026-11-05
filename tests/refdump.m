// refdump.m: decode a .mov with Apple's software H.264/HEVC decoder (AVAssetReader, hardware decode explicitly off) and
// write every frame as planar I420, which is what decodeN compares against.
//   ./refdump in.mov out.i420 [maxFrames]
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: refdump in.mov out.i420 [maxFrames]\n"); return 2; }
        const int maxFrames = argc > 3 ? atoi(argv[3]) : 1000000;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!track) { fprintf(stderr, "no video track\n"); return 1; }
        NSError *err = nil;
        AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!rd) { fprintf(stderr, "reader: %s\n", err.localizedDescription.UTF8String); return 1; }
        NSDictionary *opts = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)AVVideoDecompressionPropertiesKey : @{ @"EnableHardwareAcceleratedVideoDecoder" : @NO },
        };
        AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:opts];
        out.alwaysCopiesSampleData = NO;
        [rd addOutput:out];
        if (![rd startReading]) { fprintf(stderr, "startReading: %s\n", rd.error.localizedDescription.UTF8String); return 1; }
        FILE *f = fopen(argv[2], "wb");
        if (!f) { perror(argv[2]); return 1; }
        int n = 0;
        while (n < maxFrames) {
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (!sb) break;
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (!pb) { CFRelease(sb); continue; }
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            const size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
            const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
            const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
            const size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            uint8_t *row = malloc(w);
            for (size_t r = 0; r < h; r++) fwrite(y + r * ys, 1, w, f);
            for (size_t r = 0; r < h / 2; r++) {                 // U plane, sampled from every other byte
                for (size_t x = 0; x < w / 2; x++) row[x] = uv[r * uvs + 2 * x];
                fwrite(row, 1, w / 2, f);
            }
            for (size_t r = 0; r < h / 2; r++) {
                for (size_t x = 0; x < w / 2; x++) row[x] = uv[r * uvs + 2 * x + 1];
                fwrite(row, 1, w / 2, f);
            }
            free(row);
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            CFRelease(sb);
            n++;
            if (n % 50 == 0) fprintf(stderr, "\r%d frames", n);
        }
        fclose(f);
        fprintf(stderr, "\rdumped %d frames at %zux%zu\n", n, (size_t)0, (size_t)0);
        printf("%d\n", n);
    }
    return 0;
}
