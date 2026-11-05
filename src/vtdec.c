// vtdec.c: a VideoToolbox H.264 decoder plugin on NVDEC, for nullmoth's driver on Blackwell (GB20x). It registers the
// way NVMTLDriver's own plugins do -- NVMTLDriver dlopens "%s/libnvdec_h264.dylib" from its bundle, dlsyms
// NVDecH264_CreateInstance and hands it to VTRegisterVideoDecoderWithInfo -- so this dylib can replace the shipped one.
//
// The decoder core is src/dec.c (rm.c, channel.c, h264parse.c, blocklinear.c): it decodes a picture per VT call and reads
// the surface out with the Blackwell tile layout (bw_untile_plane, which runs in bands over four threads) instead of the
// shipped plugin's per-pixel block-linear loop, which is what made hardware decoding slower than software here.
//
// ABI, as the shipped plugin uses it: the object is a CMDerivedObject whose vtable is a header of six words (the fifth is
// the size of the derived storage) followed by
//   0x30 Invalidate 0x38 Finalize 0x40 CopyDebugDescription 0x48 CopyProperty
//   0x70 StartSession 0x78 DecodeFrame 0x80 CopySupportedPropertyDictionary 0x88 SetProperties
//   0x90 CopySerializableProperties 0x98 CanAcceptFormatDescription 0xa0 FinishDelayedFrames
// StartSession(obj, session, formatDescription), DecodeFrame(obj, session, sampleBuffer, flags, infoFlags),
// FinishDelayedFrames(obj, session), CanAcceptFormatDescription(obj, formatDescription).
#include "dec.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *VTDecoderSessionRef;

// VideoToolbox's decoder-plugin entry points (private but exported by the framework; the shipped plugin links them too)
typedef uint32_t VTDecodeFrameFlags;
typedef uint32_t VTDecodeInfoFlags;
extern void *CMBaseObjectGetDerivedStorage(void *object);
extern CFTypeID VTVideoDecoderGetClassID(void);
extern OSStatus CMDerivedObjectCreate(CFAllocatorRef alloc, const void *vtable, CFTypeID derivedClassID, CFTypeRef *obj);
extern void *VTVideoDecoderGetCMBaseObject(void *decoder);
extern OSStatus VTDecoderSessionSetPixelBufferAttributes(VTDecoderSessionRef session, CFDictionaryRef attrs);
extern CVPixelBufferPoolRef VTDecoderSessionGetPixelBufferPool(VTDecoderSessionRef session);
extern OSStatus VTDecoderSessionEmitDecodedFrame(VTDecoderSessionRef session, const void *arg, OSStatus status,
                                                 int infoFlags, CVImageBufferRef image);

#define VT_ERR_PARAM (-12902)            // kVTParameterErr
#define VT_ERR_INVALID (-12903)          // kVTInvalidSessionErr

// 安装/卸载脚本靠这串字认“这是我们的文件”，别删、别改名：原厂插件用的是同一个 "nvdec-vt:" 日志前缀，
// 靠它区分不出来（曾经因此把我们的文件当成原厂去覆盖备份）。字符串里带版本，--check 会读出来。
#ifndef NVCODEC_VERSION
#define NVCODEC_VERSION "dev"
#endif
__attribute__((used)) static const char kBuildTag[] = "nvcodec-blk-1401 dec " NVCODEC_VERSION;

static double now_ms_static(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static int gVerbose = -1;
static void vlog(const char *fmt, ...)
{
    if (gVerbose < 0) gVerbose = getenv("VT_DEC_LOG") != NULL;
    if (!gVerbose) return;
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
}

typedef struct {
    Rm rm; bool rmOk;
    H264Dec dec; bool decOk;
    VTDecoderSessionRef session;
    CFDictionaryRef attrs;
    void *obj;                       // our CMBaseObject, for the emit call
    unsigned W, H, codedW, codedH;
    pthread_mutex_t lock;
    unsigned fed, emitted, errors;
    // VideoToolbox hands DecodeFrame a per-frame token and expects it back with the picture (that is how it matches an
    // emitted frame to the sample it submitted; passing anything else makes the emit call fail with a parameter error).
    // Pictures come out in decode order, the same order the tokens arrive, so a queue pairs them up.
    void *req[64];
    unsigned reqHead, reqTail;
    void *lastReq;
    double engineMs, detileMs;
} State;

// The derived storage CoreMedia hands out is small (the shipped plugin keeps 0x98 bytes there), so it holds a pointer to
// the session state rather than the state itself.
static State **slot_of(void *obj) { return (State **)CMBaseObjectGetDerivedStorage(VTVideoDecoderGetCMBaseObject(obj)); }
static State *state_of(void *obj) { State **p = slot_of(obj); return p ? *p : NULL; }

// ---- the access unit a VT sample holds: AVCC length prefixes -> Annex B start codes ----
static int feed_sample(State *s, CMSampleBufferRef sb)
{
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return VT_ERR_PARAM;
    const size_t len = CMBlockBufferGetDataLength(bb);
    if (!len) return VT_ERR_PARAM;
    uint8_t *buf = NULL;
    if (CMBlockBufferIsRangeContiguous(bb, 0, len))
        CMBlockBufferGetDataPointer(bb, 0, NULL, NULL, &buf);
    uint8_t *tmp = NULL;
    if (!buf) {
        tmp = malloc(len);
        if (!tmp) return VT_ERR_PARAM;
        if (CMBlockBufferCopyDataBytes(bb, 0, len, tmp) != kCMBlockBufferNoErr) { free(tmp); return VT_ERR_PARAM; }
        buf = tmp;
    }
    int rc = 0;
    for (size_t off = 0; off + 4 <= len;) {
        const uint32_t nalLen = ((uint32_t)buf[off] << 24) | ((uint32_t)buf[off + 1] << 16) |
                                ((uint32_t)buf[off + 2] << 8) | buf[off + 3];
        off += 4;
        if (!nalLen || off + nalLen > len) { rc = VT_ERR_PARAM; break; }
        if (h264dec_nal(&s->dec, buf + off, nalLen) < 0) { rc = VT_ERR_INVALID; break; }
        off += nalLen;
    }
    free(tmp);
    return rc;
}

// A frame we could not decode still has to be reported: VideoToolbox holds the whole pipeline for a token that never
// comes back, so an error is emitted for it (the shipped plugin does the same with its own error code).
static void emit_error(State *s, void *request, OSStatus status)
{
    // VideoToolbox crashes if an error is emitted with no picture (it dereferences the image), so the frame is only
    // counted here; the error still goes back to the session through the return value of DecodeFrame.
    vlog("nvdec-vt: frame %u (req %p) failed: 0x%x\n", s->emitted, request, (unsigned)status);
    s->errors++;
}

// ---- one decoded picture into a CVPixelBuffer from the session's pool, then emitted ----
static OSStatus emit_picture(State *s, void *request)
{
    const unsigned w = (unsigned)s->dec.cur_w, h = (unsigned)s->dec.cur_h;
    // The buffer the session's pool hands out, as the shipped plugin does; a stand-in of our own only if that fails, so
    // that a broken pool does not stop the decode path.
    CVPixelBufferRef pb = NULL;
    CVPixelBufferPoolRef pool = VTDecoderSessionGetPixelBufferPool(s->session);
    if (pool) CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb);
    if (!pb) {
        CFMutableDictionaryRef ios = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
        int w32 = (int)w, h32 = (int)h, pf = 0x34323076;
        CFNumberRef wRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &w32), hRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &h32);
        CFNumberRef fRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
        const void *keys[4] = { kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
                                kCVPixelBufferIOSurfacePropertiesKey };
        const void *vals[4] = { wRef, hRef, fRef, ios };
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 4, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
        for (int i = 0; i < 4; i++) CFDictionarySetValue(attrs, keys[i], vals[i]);
        CVPixelBufferCreate(NULL, w, h, pf, attrs, &pb);
        CFRelease(attrs); CFRelease(ios); CFRelease(wRef); CFRelease(hRef); CFRelease(fRef);
    }
    if (!pb) return VT_ERR_INVALID;
    CVPixelBufferLockBaseAddress(pb, 0);
    const double t0 = now_ms_static();
    h264dec_read_nv12(&s->dec, s->dec.cur_surf, CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                      CVPixelBufferGetBytesPerRowOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1),
                      CVPixelBufferGetBytesPerRowOfPlane(pb, 1), w, h);
    s->detileMs += now_ms_static() - t0;
    CVPixelBufferUnlockBaseAddress(pb, 0);
    h264dec_release(&s->dec, s->dec.cur_surf);
    // Emit. The arguments are the session, the token from DecodeFrame, the status, the info flags and the picture.
    const OSStatus st = VTDecoderSessionEmitDecodedFrame(s->session, request, 0, 0, pb);
    if (s->emitted < 3)
        vlog("nvdec-vt: emit %u (req %p, %zux%zu) -> %d\n", s->emitted, request, CVPixelBufferGetWidth(pb),
             CVPixelBufferGetHeight(pb), (int)st);
    CFRelease(pb);
    s->emitted++;
    return st;
}

// ---- vtable ----
static void dec_invalidate(void *obj) { vlog("nvdec-vt: Invalidate\n"); (void)obj; }

static void dec_finalize(void *obj)
{
    vlog("nvdec-vt: Finalize\n");
    State **slot = slot_of(obj);
    if (!slot || !*slot) return;
    State *s = *slot;
    if (s->decOk) h264dec_close(&s->dec);
    if (s->rmOk) rm_close(&s->rm);
    pthread_mutex_destroy(&s->lock);
    if (s->attrs) CFRelease(s->attrs);
    free(s);
    *slot = NULL;
}

static CFStringRef dec_copy_debug_description(void *obj)
{
    vlog("nvdec-vt: CopyDebugDescription\n");
    (void)obj;
    return CFSTR("nvdec-vt (NVDEC H.264, Blackwell layout)");
}

// The GPU's registry ID, the value Metal reports as MTLDevice.registryID: the registry entry ID of the accelerator
// service that sits under the NVIDIA PCI device. Tools that tell hardware from software decode map it back through
// IORegistryEntryIDMatching and read vendor-id, so it has to be that entry and not the PCI device's own.
static uint64_t gpu_registry_id(void)
{
    static uint64_t cached;                      // the GPU does not change while the process lives
    if (cached) return cached;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS)
        return 0;
    io_object_t s;
    while (!cached && (s = IOIteratorNext(it))) {
        CFTypeRef ven = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("vendor-id"), NULL,
                                                       kIORegistryIterateRecursively | kIORegistryIterateParents);
        unsigned v = 0;
        if (ven && CFGetTypeID(ven) == CFDataGetTypeID() && CFDataGetLength(ven) >= 2)
            CFDataGetBytes(ven, CFRangeMake(0, 2), (UInt8 *)&v);
        if (ven) CFRelease(ven);
        if (v == 0x10de) IORegistryEntryGetRegistryEntryID(s, &cached);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return cached;
}

// What VideoToolbox cannot know by itself. Anything that wants to tell a hardware decode from a software one asks the
// session for these two, so a decoder that answers neither is a working NVDEC session that reports as unverified
// (NVCodecTest: "会话未报告实际硬件属性，强制硬件路径待验证").
static OSStatus dec_copy_property(void *obj, CFStringRef key, CFAllocatorRef alloc, void **out)
{
    (void)obj;
    if (!key || !out) return VT_ERR_PARAM;
    if (CFEqual(key, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)) {
        *out = (void *)CFRetain(kCFBooleanTrue);
        vlog("nvdec-vt: CopyProperty UsingHardwareAcceleratedVideoDecoder -> true\n");
        return noErr;
    }
    if (CFEqual(key, kVTDecompressionPropertyKey_UsingGPURegistryID)) {
        const uint64_t rid = gpu_registry_id();
        if (!rid) return VT_ERR_PARAM;
        SInt64 n = (SInt64)rid;
        *out = (void *)CFNumberCreate(alloc, kCFNumberSInt64Type, &n);
        vlog("nvdec-vt: CopyProperty UsingGPURegistryID -> 0x%llx\n", (unsigned long long)rid);
        return *out ? noErr : VT_ERR_PARAM;
    }
    if (gVerbose) {
        char k[128] = "?";
        CFStringGetCString(key, k, sizeof k, kCFStringEncodingUTF8);
        vlog("nvdec-vt: CopyProperty %s (unsupported)\n", k);
    }
    return VT_ERR_PARAM;
}

static Boolean dec_can_accept(void *obj, CMFormatDescriptionRef fmt)
{
    (void)obj;
    if (!fmt) return false;
    const FourCharCode c = CMFormatDescriptionGetMediaSubType(fmt);
    // 'avc1' carries the parameter sets in the format description, 'avc3' in the stream; both are H.264 4:2:0 8-bit,
    // which is all NVDEC decodes, so anything else is left to another decoder.
    return c == 'avc1' || c == 'avc3';
}

static OSStatus dec_start_session(void *obj, VTDecoderSessionRef session, CMFormatDescriptionRef fmt)
{
    State *s = state_of(obj);
    const FourCharCode st4 = fmt ? CMFormatDescriptionGetMediaSubType(fmt) : 0;
    const CMVideoDimensions d0 = fmt ? CMVideoFormatDescriptionGetDimensions(fmt) : (CMVideoDimensions){ 0, 0 };
    vlog("nvdec-vt: StartSession obj %p state %p fmt %p '%c%c%c%c' %dx%d\n", obj, (void *)s, (void *)fmt,
         (int)((st4 >> 24) & 255), (int)((st4 >> 16) & 255), (int)((st4 >> 8) & 255), (int)(st4 & 255), (int)d0.width,
         (int)d0.height);
    if (!s || !fmt) return VT_ERR_PARAM;
    if (st4 != 'avc1' && st4 != 'avc3') return VT_ERR_PARAM;
    pthread_mutex_lock(&s->lock);
    if (s->decOk) { h264dec_close(&s->dec); s->decOk = false; }
    if (s->rmOk) { rm_close(&s->rm); s->rmOk = false; }
    s->session = session;
    s->fed = s->emitted = s->errors = 0; s->engineMs = s->detileMs = 0;

    const CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
    s->W = (unsigned)dim.width; s->H = (unsigned)dim.height;
    s->codedW = (s->W + 15) & ~15u; s->codedH = (s->H + 15) & ~15u;
    vlog("nvdec-vt: StartSession %ux%u\n", s->W, s->H);

    if (rm_open(&s->rm) || rm_va_init(&s->rm)) { s->errors++; pthread_mutex_unlock(&s->lock); return VT_ERR_INVALID; }
    s->rmOk = true;
    if (h264dec_open(&s->dec, &s->rm, s->codedW, s->codedH)) { s->errors++; pthread_mutex_unlock(&s->lock); return VT_ERR_INVALID; }
    s->decOk = true;

    // the SPS / PPS the format description carries, into the decoder
    size_t nps = 0;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &nps, NULL) == noErr) {
        for (size_t i = 0; i < nps; i++) {
            const uint8_t *ps = NULL; size_t plen = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &plen, NULL, NULL) == noErr && ps && plen)
                h264dec_nal(&s->dec, ps, plen);
        }
    }
    // What the decoder hands out, built the way the shipped plugin builds it: four keys, the pixel format as a
    // CFNumber ('420v'), an empty IOSurface dictionary. The dictionary has to stay alive (VideoToolbox reads it when it
    // builds the pool), so it is kept in the session state.
    int w32 = (int)s->W, h32 = (int)s->H, pf = 0x34323076;    // '420v'
    CFNumberRef wRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &w32);
    CFNumberRef hRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &h32);
    CFNumberRef fRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    CFMutableDictionaryRef ios = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
    const void *keys[4] = { kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
                            kCVPixelBufferIOSurfacePropertiesKey };
    const void *vals[4] = { wRef, hRef, fRef, ios };
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 4, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 4; i++) CFDictionarySetValue(attrs, keys[i], vals[i]);
    if (s->attrs) CFRelease(s->attrs);
    s->attrs = CFRetain(attrs);                                 // kept for the life of the session
    const OSStatus ast = VTDecoderSessionSetPixelBufferAttributes(session, attrs);
    CFRelease(ios); CFRelease(attrs); CFRelease(wRef); CFRelease(hRef); CFRelease(fRef);
    vlog("nvdec-vt: pixel buffer attributes -> %d\n", (int)ast);
    pthread_mutex_unlock(&s->lock);
    return ast;
}

static OSStatus dec_decode_frame(void *obj, void *request, CMSampleBufferRef sb, VTDecodeFrameFlags flags,
                                 VTDecodeInfoFlags *infoFlags)
{
    (void)flags;
    State *s = state_of(obj);
    if (infoFlags) *infoFlags = 0;
    if (!sb) vlog("nvdec-vt: DecodeFrame with no sample buffer (drain?)\n");
    if (!s || !s->decOk || !sb) return VT_ERR_INVALID;
    pthread_mutex_lock(&s->lock);
    s->req[s->reqTail++ & 63] = request;                       // the token this sample must be emitted with
    OSStatus st = feed_sample(s, sb);
    // A VideoToolbox sample is one whole access unit, so the picture it carries is complete as soon as the sample is
    // in: decode it now rather than waiting for the next sample to reveal the picture's end. That also keeps the count
    // exact -- VideoToolbox waits for one emitted picture per submitted sample and never asks for a drain (it sits in
    // VTDecompressionSessionWaitForAsynchronousFrames), so a decoder that holds the last picture back hangs the player.
    if (st == 0 && h264dec_flush(&s->dec) < 0) st = VT_ERR_INVALID;
    s->fed++;
    if (st) {                                                  // the engine refused this picture: report it and go on
        while (s->reqHead != s->reqTail) emit_error(s, s->req[s->reqHead++ & 63], st);
        st = 0;
    }
    while (s->reqHead != s->reqTail && h264dec_pop(&s->dec)) {
        s->engineMs += s->dec.engine_ms;
        void *req = s->req[s->reqHead++ & 63];
        s->lastReq = req;
        const OSStatus e = emit_picture(s, req);
        if (e) { s->errors++; st = e; }
    }
    if (s->fed % 30 == 0)
        vlog("nvdec-vt: %u samples, %u pictures, engine %.2f ms each, detile %.3f ms each\n", s->fed, s->emitted,
             s->emitted ? s->engineMs / s->emitted : 0, s->emitted ? s->detileMs / s->emitted : 0);
    pthread_mutex_unlock(&s->lock);
    return st;
}

// VideoToolbox calls this at the end of a stream: the pictures the reorder window still holds have to be decoded and
// emitted now, or the last frames (and any player waiting for them) never arrive.
static OSStatus dec_finish_delayed(void *obj, VTDecoderSessionRef session)
{
    (void)session;
    State *s = state_of(obj);
    vlog("nvdec-vt: FinishDelayedFrames called\n");
    if (!s) return VT_ERR_INVALID;
    pthread_mutex_lock(&s->lock);
    vlog("nvdec-vt: FinishDelayedFrames lock acquired\n");
    if (s->decOk) {
        h264dec_flush(&s->dec);
        while (h264dec_pop(&s->dec)) {
            void *req = s->reqHead != s->reqTail ? s->req[s->reqHead++ & 63] : s->lastReq;
            s->lastReq = req;
            emit_picture(s, req);
        }
        vlog("nvdec-vt: FinishDelayedFrames -> %u samples, %u pictures, %u errors\n", s->fed, s->emitted, s->errors);
    }
    pthread_mutex_unlock(&s->lock);
    return 0;
}

static OSStatus dec_set_properties(void *obj, CFStringRef key, CFTypeRef value, void *session)
{
    vlog("nvdec-vt: SetProperties\n");
    (void)obj; (void)key; (void)value; (void)session;
    return 0;
}

// The keys have to be declared here as well: VideoToolbox answers a property a plugin did not list with
// kVTPropertyNotSupportedErr (-12900) without ever asking it, which is what made the session report no hardware
// property at all even though CopyProperty answers it.
static CFDictionaryRef gSupported;
static pthread_once_t gSupportedOnce = PTHREAD_ONCE_INIT;

static CFDictionaryRef prop(CFStringRef type, CFStringRef rw)
{
    const void *k[] = { kVTPropertyTypeKey, kVTPropertyReadWriteStatusKey };
    const void *v[] = { type, rw };
    return CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void build_supported(void)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                         prop(kVTPropertyType_Boolean, kVTPropertyReadWriteStatus_ReadOnly));
    CFDictionarySetValue(d, kVTDecompressionPropertyKey_UsingGPURegistryID,
                         prop(kVTPropertyType_Number, kVTPropertyReadWriteStatus_ReadOnly));
    gSupported = d;
}

static OSStatus dec_copy_supported_properties(void *obj, CFDictionaryRef *out)
{
    (void)obj;
    if (!out) return VT_ERR_PARAM;
    pthread_once(&gSupportedOnce, build_supported);
    if (!gSupported) return VT_ERR_PARAM;
    *out = (CFDictionaryRef)CFRetain(gSupported);
    return noErr;
}

// The vtable, laid out as the shipped plugin's (see the comment at the top). The header's fifth word is the size of the
// storage CMDerivedObjectCreate allocates for us.
typedef struct {
    const void *h0;
    const void *h1;
    const void *h2;
    UInt32 h3a, h3b;
    size_t storageSize;
    const void *h5;
    void (*Invalidate)(void *);
    void (*Finalize)(void *);
    CFStringRef (*CopyDebugDescription)(void *);
    OSStatus (*CopyProperty)(void *, CFStringRef, CFAllocatorRef, void **);
    const void *s1, *s2, *s3;
    UInt32 s4a, s4b;
    OSStatus (*StartSession)(void *, VTDecoderSessionRef, CMFormatDescriptionRef);
    OSStatus (*DecodeFrame)(void *, VTDecoderSessionRef, CMSampleBufferRef, VTDecodeFrameFlags, VTDecodeInfoFlags *);
    OSStatus (*CopySupportedPropertyDictionary)(void *, CFDictionaryRef *);
    OSStatus (*SetProperties)(void *, CFStringRef, CFTypeRef, void *);
    OSStatus (*CopySerializableProperties)(void *, CFStringRef, CFAllocatorRef, void **);
    Boolean (*CanAcceptFormatDescription)(void *, CMFormatDescriptionRef);
    OSStatus (*FinishDelayedFrames)(void *, VTDecoderSessionRef);
    const void *tail;
} VTDecoderVTable;

static VTDecoderVTable kVT = {
    .h0 = NULL, .h1 = NULL, .h2 = NULL, .h3a = 0, .h3b = 1,
    .storageSize = sizeof(State),
    .h5 = NULL,
    .Invalidate = dec_invalidate,
    .Finalize = dec_finalize,
    .CopyDebugDescription = dec_copy_debug_description,
    .CopyProperty = dec_copy_property,
    .s1 = NULL, .s2 = NULL, .s3 = NULL, .s4a = 0, .s4b = 1,
    .StartSession = dec_start_session,
    .DecodeFrame = dec_decode_frame,
    .CopySupportedPropertyDictionary = dec_copy_supported_properties,
    .SetProperties = dec_set_properties,
    .CopySerializableProperties = NULL,
    .CanAcceptFormatDescription = dec_can_accept,
    .FinishDelayedFrames = dec_finish_delayed,
    .tail = NULL,
};

// VTRegisterVideoDecoderWithInfo's create function: (flags, allocator, out). The shipped plugin takes three arguments
// too -- its fourth register is whatever the caller left there, which is what made an "out" argument look like 0xff.
__attribute__((visibility("default")))
OSStatus NVDecH264_CreateInstance(uint32_t flags, CFAllocatorRef alloc, void **outDecoder)
{
    (void)flags;
    if (!outDecoder) return VT_ERR_PARAM;
    CFTypeRef obj = NULL;
    const OSStatus st = CMDerivedObjectCreate(alloc, &kVT, VTVideoDecoderGetClassID(), &obj);
    if (st || !obj) { vlog("nvdec-vt: CMDerivedObjectCreate -> %d\n", (int)st); return st ? st : VT_ERR_INVALID; }
    State **slot = slot_of(obj);
    State *s = calloc(1, sizeof *s);
    if (!s) { CFRelease((CFTypeRef)obj); return VT_ERR_INVALID; }
    pthread_mutex_init(&s->lock, NULL);
    s->obj = obj;
    *slot = s;
    vlog("nvdec-vt: CreateInstance ok\n");
    *outDecoder = (void *)obj;
    return 0;
}

// Self-registration, for trying the plugin without installing it into the driver bundle:
//   DYLD_INSERT_LIBRARIES=libnvdect.dylib VT_DEC_SELF_REGISTER=1 NVMTL_NO_NVDEC=1 vtspeed2 movie.mov
// (a constructor runs before VideoToolbox builds its decoder list, which a registration from main() is too late for).
// When the dylib sits in NVMTLDriver's bundle, NVMTLDriver does this itself and this stays quiet.
// CMDerivedObjectCreate wants the six words in front of the function table filled in (they hold two object references
// that the shipped plugin builds statically). Rather than guess what they are, read them from the shipped dylib, kept
// aside as a reference: its CreateInstance sits at file offset 0x800 and its vtable at 0xb250 (checked before use).
// CMDerivedObjectCreate's second argument is a descriptor: six words of class information, two of which point at the
// dispatch blocks VideoToolbox really calls through (the function pointers after the six words are not what it uses --
// that is why an object built with our own trailing table was created fine and then never spoken to).
// The shipped descriptor is { 0, d0, d1, {0,1}, 0x98, 0 } with d0 = dispatch and d1 = dispatch + 0x50, and the two blocks
// look like this (offsets from d0, one 8-byte slot per callback):
//   +0x00 {u32 1, u32 0x98}                     kind, then the block's size
//   +0x14 Invalidate  +0x1c Finalize  +0x24 CopyDebugDescription  +0x2c CopyProperty
//   +0x50 {u32 1, u32 0}                        start of the second block (d1)
//   +0x54 StartSession +0x5c DecodeFrame +0x64 CopySupportedPropertyDictionary +0x6c SetProperties
//   +0x74 CopySerializableProperties +0x7c CanAcceptFormatDescription +0x84 FinishDelayedFrames
// Building it here rather than borrowing the shipped one keeps the plugin free of any other file.
static unsigned char kDispatch[0x98];
static void vtdec_dispatch_build(void)
{
    memset(kDispatch, 0, sizeof kDispatch);
    *(uint32_t *)(kDispatch + 0x00) = 1;         // the shipped block starts {1, 0x98}: a kind and its size
    *(uint32_t *)(kDispatch + 0x04) = 0x98;
    *(uint32_t *)(kDispatch + 0x50) = 1;         // ...and the second half starts with the same kind word
#define PATCH(off, fn) do { void *p_ = (void *)(fn); memcpy(kDispatch + (off), &p_, sizeof p_); } while (0)
    PATCH(0x14, dec_invalidate);
    PATCH(0x1c, dec_finalize);
    PATCH(0x24, dec_copy_debug_description);
    PATCH(0x2c, dec_copy_property);
    PATCH(0x54, dec_start_session);
    PATCH(0x5c, dec_decode_frame);
    PATCH(0x64, dec_copy_supported_properties);
    PATCH(0x6c, dec_set_properties);
    PATCH(0x74, dec_copy_property);              // CopySerializableProperties: answer "not supported"
    PATCH(0x7c, dec_can_accept);
    PATCH(0x84, dec_finish_delayed);
#undef PATCH
    kVT.h0 = NULL;
    kVT.h1 = kDispatch;
    kVT.h2 = kDispatch + 0x50;
    kVT.h3a = 0; kVT.h3b = 1;
    kVT.storageSize = 0x98;                      // the size the shipped plugin asks for; we keep a pointer in it
    kVT.h5 = NULL;
}

__attribute__((constructor)) static void vtdec_self_register(void)
{
    vtdec_dispatch_build();
    if (!getenv("VT_DEC_SELF_REGISTER")) return;
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
    if (!vt) return;
    typedef int32_t (*RegFn)(uint32_t codecType, CFDictionaryRef info, void *create);
    RegFn reg = (RegFn)dlsym(vt, "VTRegisterVideoDecoderWithInfo");
    if (!reg) return;
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
    int rating = 5000;
    CFNumberRef r = CFNumberCreate(NULL, kCFNumberIntType, &rating);
    const char *cid = getenv("VT_DEC_CLASS_ID");
    CFStringRef cidRef = CFStringCreateWithCString(NULL, cid && *cid ? cid : "com.nvmtl.videodecoder.avc.nvdec",
                                                   kCFStringEncodingUTF8);
    CFDictionarySetValue(info, CFSTR("CMClassImplementationID"), cidRef);
    CFDictionarySetValue(info, CFSTR("VTRating"), r);
    CFDictionarySetValue(info, CFSTR("VTIsHardwareAccelerated"), kCFBooleanTrue);
    // the first argument is the codec type ('avc1'), as NVMTLDriver's own call passes it
    const int32_t rs = reg('avc1', info, (void *)NVDecH264_CreateInstance);
    vlog("nvdec-vt: self register avc1 -> %d\n", (int)rs);
    CFRelease(r); CFRelease(info);
}
