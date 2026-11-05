# nvcodec-blackwell — 50 系硬解

> Fork of [mickys/nvenc](https://github.com/mickys/nvenc) · runs on [NullMoth's NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver) · [中文说明](#中文说明)

H.264 hardware **decode and encode** for NVIDIA Blackwell (GB20x, RTX 50) on macOS, through VideoToolbox,
on top of [NullMoth's NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver). A fork of
[mickys/nvenc](https://github.com/mickys/nvenc) that adds Blackwell and a faster read-out path.

The driver already decodes H.264 on these cards, but its plug-in copies every pixel out of the NVDEC
surface one block at a time. This one walks the surface in 512-byte bands across four threads, which is
where the 3× comes from — same engine, same picture, less CPU.

## Performance

RTX 5070 Ti (GB203), macOS 26.7.2, driver 2.7.1, 8–30 Mbps H.264 4:2:0 8-bit:

| | this plug-in | stock plug-in | Apple software |
|---|---|---|---|
| H.264 1080p decode | **700–920 fps** | 235–239 fps | 471 fps |
| H.264 4K decode | **229 fps** | — | — |
| H.264 1080p encode | **718 fps** | (hardware, same engine) | 156 fps |
| H.264 4K encode | **159 fps** | — | — |

Correctness, not just throughput: 300 decoded frames are **byte-identical** to Apple's software decoder,
and the encoder lands 32.1 dB PSNR at the bitrate where Apple's software encoder gets 28.6 dB.

## Install

Download the release (`.pkg` to double-click, or `.tar.gz` to read the scripts), or build it yourself:

```sh
sudo ./install.sh --check    # driver version, GPU id, what is installed now (changes nothing)
sudo ./install.sh
```

`install.sh` replaces `libnvdec_h264.dylib` inside the driver bundle (keeping the original as
`libnvdec_h264.dylib.vendor`, created once and never overwritten) and drops `libnvencvt.dylib` next to it.
Uninstall with `sudo ./uninstall.sh`: it restores the backup if there is one, otherwise it turns the
plug-ins off through the driver's own configuration switches.

## 中文说明

- **适用范围**：Blackwell（GB20x）——RTX 5060 / 5060 Ti / 5070 / 5070 Ti / 5080 / 5090，驱动为 nullmoth 1401 / NVRM 2.7.x，macOS 15+ x86_64 黑苹果。
- **装什么**：只做 H.264。解码插件替换驱动里的 `libnvdec_h264.dylib`，编码插件是外挂的 `libnvencvt.dylib`；HEVC 完全不碰，继续用驱动自带的。
- **装/卸**：`sudo ./install.sh --check` 先体检，`sudo ./install.sh` 安装，`sudo ./uninstall.sh` 回退。
- **驱动升级后**：新版驱动会把插件文件覆盖回官方版本，重跑一次 `install.sh` 即可。装完 `--check` 应显示"已安装（我们的版本）"。
- **实测数字**：1080p 解码 700–920 fps（软解 471），4K 解码 229 fps，1080p 编码 718 fps（软编 156）。

## Build

```sh
./fetch-vendor.sh    # NVIDIA headers into vendor/ (not committed)
sh build.sh          # build/libnvdec_h264.dylib, build/libnvencvt.dylib
sh build.sh tools    # plus the test programs
```

`fetch-vendor.sh` pins `open-gpu-kernel-modules` at tag `620.70.06`; the class headers come from
`open-gpu-doc`. Both are read-only inputs — no NVIDIA code is vendored into this repository.

## Tests

`tests/` holds the VideoToolbox harnesses used for the numbers above (`vtprops3` reports what a decoder
session claims about itself and then times a decode; `hevcchk` encodes and decodes back for PSNR;
`vtplugtest` loads a plug-in dylib into a normal app without installing it). They need their own clips;
see `tests/README.md`. `bin/`-style prebuilt tools are not committed — `sh build.sh tools` makes them.

## How it works

The Blackwell surface layout is not the block-linear one the rest of the driver uses: a 64-byte by 16-row
tile, with 8×8 blocks inside, so

```
offset(x, y) = (y/16)*pitch*16 + (x/tp)*1024 + ((y%16)/8)*512 + ((x%tp)/8)*64*bpp + (y%8)*br + (x%8)*bpp
```

with `tp = 64/bpp`, `br = 8*bpp`. `src/blocklinear.c` reads that in bands, four threads via `dispatch_apply`,
with a separate tail path for pictures whose height is not a multiple of 16. The same routine serves any
codec that comes out of NVDEC in this layout. Derivation, ABI notes and the dead ends are in
[docs/BLACKWELL-LAYOUT.zh-CN.md](docs/BLACKWELL-LAYOUT.zh-CN.md) (Chinese).

## Limitations

- **HEVC is not touched.** The shipped HEVC decoder and encoder work on these cards (717 fps 1080p decode,
  707 fps encode, verified `hvc1` output at 45 dB PSNR) and keep doing the job. This fork's own HEVC core
  hangs on P pictures on Blackwell, so it is not built into the H.264 plug-in.
- **AV1 is not ported.** The upstream AV1 paths are Ada-only.
- **GPU attribution**: `kVTDecompressionPropertyKey_UsingGPURegistryID` is answered by VideoToolbox itself,
  not by the plug-in, so diagnostic tools show "hardware, device not reported" even when it is the NVIDIA
  card. Nothing a plug-in can do about it.
- **Driver updates replace the plug-ins.** Reinstall after each driver update; `--check` tells you which
  version is in place.
- 8-bit 4:2:0 H.264 only. 10-bit, 4:2:2 and 4:4:4 are not wired up in the decoder plug-in.

## Licence

MIT, see [LICENSE](LICENSE). Derived from [mickys/nvenc](https://github.com/mickys/nvenc) (MIT); see [NOTICE](NOTICE) for what came from
where, and for the terms of the driver this plugs into. Unofficial project — not affiliated with NVIDIA,
Apple or NullMoth Systems.
