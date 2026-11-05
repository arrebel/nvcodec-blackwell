// spy.c — find the command stream a decoder plugin builds, by scanning this process's writable memory for the
// NVDEC method word of SET_APPLICATION_ID followed by the HEVC application id. Injected with
// DYLD_INSERT_LIBRARIES into the process that decodes, it dumps the surrounding dwords so the shipped plugin's exact
// method order and setup values can be read out.
//   DYLD_INSERT_LIBRARIES=/tmp/nvb/libspy.dylib VTS_... vtspeed2 movie.mov
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SET_APPLICATION_ID_WORD 0x20010040u    // (1<<29) | (count 1 << 16) | (0x100 >> 2)
#define ID_HEVC 7u
#define ID_H264 3u

static int gDumped;

static void dump_words(const uint32_t *p, size_t n, const char *tag)
{
    char path[128];
    snprintf(path, sizeof path, "/tmp/nvdec-spy-%s.txt", tag);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "# %zu dwords at %p\n", n, (const void *)p);
    for (size_t i = 0; i < n;) {
        const uint32_t w = p[i];
        if ((w >> 29) == 1 && (w & 0x1fff)) {                 // INC_METHOD: 1 + count dwords
            const unsigned cnt = (w >> 16) & 0x1fff;
            fprintf(f, "%04zx: mthd 0x%04x count %u:", i, (w & 0x1fff) << 2, cnt);
            for (unsigned k = 0; k < cnt && i + 1 + k < n; k++) fprintf(f, " %08x", p[i + 1 + k]);
            fprintf(f, "\n");
            i += 1 + cnt;
        } else {
            fprintf(f, "%04zx: %08x\n", i, w);
            i++;
        }
    }
    fclose(f);
    fprintf(stderr, "spy: wrote %s\n", path);
}

static void scan(void)
{
    vm_address_t addr = 0;
    unsigned long long scanned = 0;
    while (1) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,
                         &object) != KERN_SUCCESS)
            break;
        if ((info.protection & VM_PROT_WRITE) && size >= 0x1000 && size <= (512u << 20)) {
            scanned += size;
            const uint32_t *p = (const uint32_t *)addr;
            const size_t n = size / 4;
            for (size_t i = 0; i + 2 < n; i++) {
                if (p[i] != SET_APPLICATION_ID_WORD) continue;
                const uint32_t id = p[i + 1];
                if (id != ID_HEVC && id != ID_H264) continue;
                if (gDumped > 3) return;
                gDumped++;
                // the stream starts a little before this method; dump a window and a long tail
                const size_t back = i > 64 ? 64 : i;
                char tag[32];
                snprintf(tag, sizeof tag, "%d-%d", (int)getpid(), gDumped);
                dump_words(p + (i - back), 1600, tag);
            }
        }
        addr += size;
    }
    if (!gDumped) {
        static int once;
        if (!once++) { FILE *l = fopen("/tmp/nvdec-spy-log.txt", "w"); if (l) { fprintf(l, "scanned %llu MB, no hit\n", scanned >> 20); fclose(l); } }
    }
}

static void *thread_main(void *arg)
{
    (void)arg;
    // give the player time to open the file and submit the first pictures
    usleep(30 * 1000);
    for (int k = 0; k < 200; k++) {
        scan();
        if (gDumped) break;
        usleep(30 * 1000);
    }
    return NULL;
}

__attribute__((constructor)) static void spy_start(void)
{
    // VideoToolbox decodes inside VTDecoderXPCService, whose environment we cannot set from here, so the switch is a
    // file: touch /tmp/nvdec-spy-on, restart the service, decode.
    if (!getenv("NVDEC_SPY") && access("/tmp/nvdec-spy-on", F_OK)) return;
    pthread_t t;
    pthread_create(&t, NULL, thread_main, NULL);
    pthread_detach(t);
}
