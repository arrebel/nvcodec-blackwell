// bwbench.c: how fast can a Blackwell surface be turned into pitch-linear NV12 on the CPU?
#include "blocklinear.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>

static volatile unsigned long long gSum;
static double now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}

// the same job, but the eight blocks of a tile are transposed into a scratch buffer first, so the
// destination is written in full 64-byte lines instead of eight-byte pieces
static void untile_transposed(uint8_t *dst,size_t dst_stride,const uint8_t *src,size_t width,size_t rows,size_t pitch,size_t bpp)
{
    const size_t tp=(64/bpp), rowb=tp*bpp, bands=rows/16;
    for(size_t b=0;b<bands;b++){
        const uint8_t *base=src+b*pitch*16; uint8_t *d0=dst+b*16*dst_stride;
        for(size_t t=0;t<width/tp;t++)
            for(int g=0;g<2;g++){
                uint8_t tmp[16*64];
                const uint8_t *s0=base+t*1024+g*512;
                for(size_t k=0;k<8/bpp;k++){
                    const uint8_t *s=s0+k*64*bpp;
                    for(int r=0;r<8;r++) memcpy(tmp+r*rowb+k*8*bpp, s+r*8*bpp, 8*bpp);
                }
                for(int r=0;r<8;r++) memcpy(d0+(g*8+r)*dst_stride+t*rowb, tmp+r*rowb, rowb);
            }
    }
}

int main(int argc,char **argv)
{
    const size_t W=1920,H=1080, pitch=((W+63)&~(size_t)63)+256, N=argc>1?atoi(argv[1]):20;
    const size_t luma=pitch*((H+15)&~(size_t)15), chroma=pitch*((H/2+15)&~(size_t)15);
    uint8_t *src=malloc(luma+chroma), *dst=malloc(W*H*3/2), *dst2=malloc(W*H*3/2);
    memset(src,0x5a,luma+chroma);
    for(size_t y=0;y<H;y++) for(size_t x=0;x<W;x++) src[bw_offset(x,y,pitch,1)]=(uint8_t)(x*7+y*13);
    for(size_t y=0;y<H/2;y++) for(size_t x=0;x<W/2;x++) src[luma+bw_offset(x,y,pitch,2)]=(uint8_t)(x*3+y*5);
    const double bytes=(double)W*H*3/2;

    double t0=now_ms();
    for(int i=0;i<N;i++) bw_untile_plane(dst,W,src,W,H,pitch,1), bw_untile_plane(dst+W*H,W,src+luma,W/2,H/2,pitch/2,2); gSum += dst[777];
    double t1=now_ms();
    double ms1=(t1-t0)/N;

    t0=now_ms();
    for(int i=0;i<N;i++) untile_transposed(dst2,W,src,W,H,pitch,1), untile_transposed(dst2+W*H,W,src+luma,W/2,H/2,pitch/2,2); gSum += dst2[777];
    t1=now_ms();
    double ms2=(t1-t0)/N;

    t0=now_ms();
    for(int i=0;i<N;i++) memcpy(dst2,src,W*H), memcpy(dst2+W*H,src+luma,W*H/2); gSum += dst2[777];
    t1=now_ms();
    double ms3=(t1-t0)/N;

    printf("(checksum %llu)\n", gSum);
    printf("1080p NV12  %.2f MB\n", bytes/1e6);
    printf("  当前实现 (8 字节碎片写) : %6.3f ms  %5.1f GB/s\n", ms1, bytes/ms1/1e6);
    printf("  转置后 64 字节连续写    : %6.3f ms  %5.1f GB/s   (%.2fx)\n", ms2, bytes/ms2/1e6, ms1/ms2);
    printf("  memcpy 基线              : %6.3f ms  %5.1f GB/s\n", ms3, bytes/ms3/1e6);
    printf("  与基线比: 当前 %.0f%%, 转置 %.0f%%\n", ms3/ms1*100, ms3/ms2*100);
    return 0;
}
