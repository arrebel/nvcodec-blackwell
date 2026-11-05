// vtplugtest.m: load a VideoToolbox decoder plugin dylib the way NVMTLDriver does (dlopen, dlsym NVDecH264_CreateInstance,
// VTRegisterVideoDecoderWithInfo) and decode a movie with AVFoundation, so a plugin can be tried without installing it
// into the driver bundle (that needs root).
//   ./vtplugtest plugin.dylib movie.mov [maxFrames]
// Prints which decoder VideoToolbox chose (the plugin logs its own StartSession / DecodeFrame lines to stderr).
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef int32_t (*VTRegisterFn)(CFStringRef decoderID, CFDictionaryRef decoderInfo, void *createInstance);

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: vtplugtest plugin.dylib movie.mov [maxFrames]\n"); return 2; }
        const int maxFrames = argc > 3 ? atoi(argv[3]) : 100000;

        void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!h) { fprintf(stderr, "dlopen %s: %s\n", argv[1], dlerror()); return 1; }
        void *create = dlsym(h, "NVDecH264_CreateInstance");
        if (!create) { fprintf(stderr, "%s has no NVDecH264_CreateInstance\n", argv[1]); return 1; }
        VTRegisterFn reg = (VTRegisterFn)dlsym(RTLD_DEFAULT, "VTRegisterVideoDecoderWithInfo");
        if (!reg) { fprintf(stderr, "no VTRegisterVideoDecoderWithInfo\n"); return 1; }

        CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
        CFNumberRef rating = CFNumberCreate(NULL, kCFNumberIntType, &(int){ 5000 });
        CFDictionarySetValue(info, CFSTR("VTRating"), rating);
        CFDictionarySetValue(info, CFSTR("VTIsHardwareAccelerated"), kCFBooleanTrue);
        const char *idEnv = getenv("VT_DEC_ID");
        CFStringRef decoderID = CFStringCreateWithCString(NULL, idEnv ? idEnv : "com.nvmtl.videodecoder.avc.nvdec",
                                                          kCFStringEncodingUTF8);
        CFStringRef classID = CFStringCreateWithCString(NULL, getenv("VT_DEC_CLASS") ? getenv("VT_DEC_CLASS") : "com.nvmtl.nvdec.avc",
                                                        kCFStringEncodingUTF8);
        CFDictionarySetValue(info, CFSTR("CMClassImplementationID"), classID);
        const int32_t rs = reg(decoderID, info, create);
        fprintf(stderr, "register -> %d\n", rs);

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!track) { fprintf(stderr, "no video track\n"); return 1; }
        NSError *err = nil;
        AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!rd) { fprintf(stderr, "reader: %s\n", err.localizedDescription.UTF8String); return 1; }
        NSDictionary *opts = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:opts];
        out.alwaysCopiesSampleData = NO;
        [rd addOutput:out];
        if (![rd startReading]) { fprintf(stderr, "startReading: %s\n", rd.error.localizedDescription.UTF8String); return 1; }

        const double t0 = CFAbsoluteTimeGetCurrent();
        int n = 0;
        while (n < maxFrames) {
            CMSampleBufferRef sb = [out copyNextSampleBuffer];
            if (!sb) break;
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (pb) {                                                // touch the pixels so nothing is optimised away
                CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                volatile uint8_t v = *(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
                (void)v;
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            }
            CFRelease(sb);
            n++;
        }
        const double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("%d frames in %.1f ms -> %.0f fps, status %d\n", n, dt * 1000, n / dt, (int)rd.status);
    }
    return 0;
}
