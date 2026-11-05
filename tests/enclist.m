// enclist.m — 列出系统里所有 VideoToolbox 编码器（判断 NVENC 插件是否注册成功）
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
int main(void) {
    @autoreleasepool {
        CFArrayRef list = NULL;
        OSStatus st = VTCopyVideoEncoderList(NULL, &list);
        if (st != noErr || !list) { printf("VTCopyVideoEncoderList -> %d\n", (int)st); return 1; }
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            NSNumber *codecN = d[(id)kVTVideoEncoderList_CodecType];
            const unsigned c = codecN ? codecN.unsignedIntValue : 0;
            if (c != 'avc1' && c != 'hvc1') continue;
            printf("%c%c%c%c hw=%-3s %-28s id=%s\n",
                   (int)((c >> 24) & 255), (int)((c >> 16) & 255), (int)((c >> 8) & 255), (int)(c & 255),
                   [d[(id)kVTVideoEncoderList_IsHardwareAccelerated] boolValue] ? "yes" : "no",
                   [(d[(id)kVTVideoEncoderList_EncoderName] ?: @"?") UTF8String],
                   [(d[(id)kVTVideoEncoderList_EncoderID] ?: @"?") UTF8String]);
        }
        CFRelease(list);
        return 0;
    }
}
