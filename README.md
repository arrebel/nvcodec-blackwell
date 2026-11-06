# nvcodec-blackwell — 50 系硬解

> **Ported from [mickys/nvenc](https://github.com/mickys/nvenc) — H.264 only（只移植了 H.264）** · runs on [NullMoth's NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver) · [中文说明](#中文说明)

> 🧪 **For testing only / 仅供测试。** An unofficial, experimental plug-in for a Hackintosh driver — not
> production software. No warranty, no support, and it can stop working after any driver update. Do not
> rely on it for important exports, archival or playback; keep a working software fallback.

> ⚠️ **Verified on real hardware: RTX 5070 Ti (GB203) and RTX 5060 Ti (GB206).** The code covers the
> whole GB20x family by device-id and class, but no other RTX 50 card has been tested. See
> [Verified hardware](#verified-hardware).

H.264 hardware **decode and encode** for NVIDIA Blackwell (GB20x, RTX 50) on macOS, through VideoToolbox,
on top of [NullMoth's NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver).

**This is a port of the H.264 part of [mickys/nvenc](https://github.com/mickys/nvenc).** That project
implements NVENC / NVDEC VideoToolbox plug-ins for the 40-series (Ada) cards; its `src/` (`blocklinear`,
`dec`, `enc`, `hevcdec`, `channel`) and `vt/` plug-in ABI are the basis of everything here. This repository
ports **only the H.264 decode / encode path** to Blackwell: GB20x device/class detection, the 64-byte ×
16-row surface layout, a faster banded read-out path, and the VideoToolbox property reporting. See
[Scope](#scope) — the other codec sources remain upstream baseline only. Without mickys/nvenc there would
be nothing to port — all credit for the original codec work belongs there.

The driver already decodes H.264 on these cards, but its plug-in copies every pixel out of the NVDEC
surface one block at a time. This one walks the surface in 512-byte bands across four threads, which is
where the 3× comes from — same engine, same picture, less CPU.

## Verified hardware

**Two cards have been tested on real hardware:**

| Card | GPU / PCI id | macOS | NullMoth driver | What was run |
|---|---|---|---|---|
| RTX 5070 Ti | GB203, `0x2c05` | 26.7.2 | 2.7.1 | Full H.264 decode/encode benchmark, 4K, PSNR and byte-identity checks (all numbers below) |
| RTX 5060 Ti 8 GB | GB206, `0x2d04` | 26.7.2 (25G332) | 2.7.2 | 2026-11-06: H.264 1080p hardware decode, 120/120 frames, **779–800 fps** over two sessions; encoder plug-in registered as `org.nvenc.videoencoder.avc` (`mickys/nvenc 0.9.5-bw`) |

The 5060 Ti run also confirms the plug-ins load on driver 2.7.2, not just the 2.7.1 used on the
5070 Ti. Only the 1080p decode path was benchmarked on the 5060 Ti — 4K, encode throughput, PSNR
and byte-identity were measured on the 5070 Ti only. As usual, VideoToolbox does not report the GPU
registry id for these sessions (see [Limitations](#limitations)), so these runs are classified as
"hardware decode confirmed" rather than "GPU attribution confirmed".

The code is written for the whole GB20x family (device-id `0x2a00`–`0x2fff`, NVDEC `0xcfb0`,
NVENC `0xcfb7`), and the surface layout is derived from bytes-per-pixel and pitch rather than a
card-specific constant — so RTX 5060 / 5070 / 5080 / 5090 *should* take the same path.
But **none of those has been run**. Two things can still differ on an untested card: whether the
NullMoth driver itself supports that GPU, and which NVENC engine index opens (the encoder retries
with the other engine if `0x1c` fails). On a new card, run `sudo ./install.sh --check` and then a
decode/encode benchmark; if anything fails, `sudo ./uninstall.sh` rolls back cleanly.

**实机已在两张卡上验证：RTX 5070 Ti（GB203）与 RTX 5060 Ti（GB206，PCI `0x2d04`）**。5060 Ti 上是
macOS 26.7.2 (25G332) + 驱动 2.7.2，1080p H.264 硬解两轮分别 781 / 798 fps（每轮取 3 次中位数，
120/120 帧无丢帧），编码插件也正常注册；完整基准（4K、编码、PSNR、逐字节比对）仍只在 5070 Ti 上跑过。
其余 50 系型号（5060 / 5070 / 5080 / 5090）均未经测试。代码覆盖整个 GB20x，但「应该能跑」
不等于「验证可用」；换卡请先体检再实测，有问题用 `uninstall.sh` 回退。

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

On the RTX 5060 Ti (GB206, driver 2.7.2) a separate 1080p hardware-decode run measured **779–800 fps**
(120/120 frames, median of 3 rounds, two sessions on 2026-11-06). The 4K, encode and correctness
numbers above are from the 5070 Ti only.

## Install

Download the release: `.pkg` to install by double-clicking, `.tar.gz` to read the scripts, and
`NVCODEC-Blackwell-1401-Uninstall.pkg` to uninstall by double-clicking. Or build them yourself:

```sh
sudo ./install.sh --check    # driver version, GPU id, what is installed now (changes nothing)
sudo ./install.sh
```

`install.sh` replaces `libnvdec_h264.dylib` inside the driver bundle (keeping the original as
`libnvdec_h264.dylib.vendor`, created once and never overwritten) and drops `libnvencvt.dylib` next to it.
Uninstall with `sudo ./uninstall.sh`: it restores the backup if there is one, otherwise it turns the
plug-ins off through the driver's own configuration switches. The standalone `...-Uninstall.pkg` does
the same thing from the GUI and also removes the helper files installed by the `.pkg`; it carries no
plug-in binaries and never touches the driver installation itself.

## 中文说明

- **用途**：**仅供测试**。非官方、实验性插件，无担保、无支持；它替换第三方驱动里的插件文件，驱动升级后
  可能失效，且目前只在两张卡上实机验证过。不要用于重要导出、归档或生产工作流，务必保留软件编解码作为退路。
- **来源**：**移植自 [mickys/nvenc](https://github.com/mickys/nvenc) 的 H.264 部分**（MIT）。那套项目是给
  40 系（Ada）写的 NVENC/NVDEC VideoToolbox 插件；本仓库沿用它的 `src/`（分块排布、解码、编码、通道层）和
  `vt/` 插件 ABI，在此之上**只把 H.264 解码/编码路径**移植到 Blackwell：GB20x 设备/class 识别、64 字节 ×
  16 行显存排布、按 band 并行的读出路径，以及 VideoToolbox 硬件属性申报。编解码本体全部来自 mickys 的工作，
  这里只做 50 系适配与加速；其他编解码器源码是未移植的上游基线，见 [Scope](#scope)。
- **实机验证**：**RTX 5070 Ti（GB203，PCI `0x2c05`）**，macOS 26.7.2，NVRM 2.7.1 / 1401；**RTX 5060 Ti
  8 GB（GB206，PCI `0x2d04`）**，macOS 26.7.2 (25G332)，NVRM 2.7.2，2026-11-06 实测 1080p H.264 硬解
  781 / 798 fps、编码插件注册成功。均为 x86_64 黑苹果。
- **适用范围**：代码按整个 GB20x 写（device-id `0x2a00`–`0x2fff`），显存排布由每像素字节数与 pitch 推导，
  理论覆盖 RTX 5060 / 5060 Ti / 5070 / 5080 / 5090，**除上述两张卡外其余型号均未实测**。未验证的卡上还有两个
  变数：驱动本身是否支持该 GPU，以及 NVENC 引擎编号（打不开 `0x1c` 时会自动换另一个重试）。换卡请先
  `sudo ./install.sh --check`，再跑一次解码/编码实测；异常用 `sudo ./uninstall.sh` 完整回退。
- **装什么**：**只移植、只启用、只验证了 H.264**（解码 + 编码）。解码插件替换驱动里的
  `libnvdec_h264.dylib` 并只注册 `'avc1'`；编码插件是外挂的 `libnvencvt.dylib`，Blackwell 上只注册 H.264。
  仓库 `src/` 里还有 HEVC / AV1 / VP9 等上游源码，那只是链接公共代码所需的上游基线，**没有移植、没有注册、
  没有验证**；HEVC 完全不碰，解码和编码继续用驱动自带的插件。详见 [Scope](#scope)。
- **装/卸**：`sudo ./install.sh --check` 先体检，`sudo ./install.sh` 安装，`sudo ./uninstall.sh` 回退；
  不想用命令行也可双击 Release 里的 `NVCODEC-Blackwell-1401-Uninstall.pkg`（独立卸载包，不含插件二进制）。
- **驱动升级后**：新版驱动会把插件文件覆盖回官方版本，重跑一次 `install.sh` 即可。装完 `--check` 应显示"已安装（我们的版本）"。
- **实测数字**：完整基准均来自 RTX 5070 Ti / GB203：1080p 解码 700–920 fps（软解 471），4K 解码 229 fps，
  1080p 编码 718 fps（软编 156）。RTX 5060 Ti / GB206 上另测得 1080p 硬解 779–800 fps。

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

## Scope

只移植了 H.264：

**Only mickys' H.264 decoder and H.264 encoder are ported, enabled and tested here.** Nothing else in the
upstream tree was ported to Blackwell.

- The decoder plug-in (`libnvdec_h264.dylib`) is built from `rm.c`, `channel.c`, `blocklinear.c`,
  `h264parse.c`, `dec.c`, `vtdec.c` and registers **only `'avc1'` (H.264)** with VideoToolbox.
- The encoder plug-in registers **only H.264** on Blackwell. HEVC encoding is deliberately left to the
  driver's own plug-in because ours faults on the first picture; AV1 is an Ada-only upstream path.
- `src/` still contains the full upstream source tree — `hevcdec.c`, `av1dec.c`, `vp9dec.c`, `mpeg2dec.c`,
  `vc1dec.c` and friends — and `build.sh` links all of `src/*.c` into the encoder dylib (the decoder dylib
  only compiles the six H.264 files). **Those extra files are the untouched upstream baseline, not ports.**
  They are not registered with VideoToolbox and are not verified on Blackwell; the encoder plug-in exports
  only `NVEncVT_Register` / `NVEncVT_CreateInstance` and registers only H.264 on Blackwell. Our own HEVC
  decoder core hangs on P pictures on Blackwell; the upstream AV1 path is Ada-only. Do not read their
  presence as support.

**本仓库只移植了 mickys 的 H.264 解码与 H.264 编码，并在 Blackwell 上启用、验证。** `src/` 里其余编解码器
源码（HEVC、AV1、VP9、MPEG2、VC1 等）是随上游保留的原始文件，构建时 `build.sh` 会把 `src/*.c` 全部链进
编码插件（解码插件只编译 6 个 H.264 文件），但它们**没有移植到 Blackwell、没有注册、没有验证**；编码插件
只导出 `NVEncVT_Register` / `NVEncVT_CreateInstance`，在 Blackwell 上只注册 H.264。HEVC 解码核在 P 帧挂死，
AV1 上游路径只支持 Ada。HEVC 编解码继续由驱动自带的插件负责，本包不替换它们。

## Limitations

- **For testing only.** Unofficial, experimental, not production software — no warranty or support. It
  replaces a plug-in inside a third-party driver, may break on driver updates, and has only been run on
  two GPUs. Keep the software path available as a fallback.
- **Verified on RTX 5070 Ti (GB203) and RTX 5060 Ti (GB206) only.** Other GB20x cards are supported by
  the code but untested on real hardware — see [Verified hardware](#verified-hardware). All 4K, encode
  and correctness numbers in this README come from the 5070 Ti; the 5060 Ti only has a 1080p decode run.
- **HEVC is not touched.** The shipped HEVC decoder and encoder work on these cards (717 fps 1080p decode,
  707 fps encode, verified `hvc1` output at 45 dB PSNR) and keep doing the job. This repository's own HEVC core
  hangs on P pictures on Blackwell, so it is not built into the H.264 plug-in.
- **AV1 is not ported.** The upstream AV1 paths are Ada-only.
- **GPU attribution**: `kVTDecompressionPropertyKey_UsingGPURegistryID` is answered by VideoToolbox itself,
  not by the plug-in, so diagnostic tools show "hardware, device not reported" even when it is the NVIDIA
  card. Nothing a plug-in can do about it.
- **Driver updates replace the plug-ins.** Reinstall after each driver update; `--check` tells you which
  version is in place.
- 8-bit 4:2:0 H.264 only. 10-bit, 4:2:2 and 4:4:4 are not wired up in the decoder plug-in.

## Credits / 致谢

**本项目移植自 [mickys/nvenc](https://github.com/mickys/nvenc) 的 H.264 部分**（MIT）。mickys 实现了
40 系（Ada）上 NVENC/NVDEC 的视频编解码核心与 VideoToolbox 插件，本仓库的编解码代码、通道层、插件 ABI
都来自那里；这里只把 **H.264** 移植到 Blackwell（GB20x）并优化读出路径。原始编解码工作的全部功劳归于 mickys。

This project is a **port of the H.264 part of [mickys/nvenc](https://github.com/mickys/nvenc)** (MIT). The
NVENC/NVDEC codec cores, channel layer and VideoToolbox plug-in ABI all come from that project; this
repository ports only the H.264 path to Blackwell and speeds up the surface read-out. All credit for the
original codec work goes to mickys.

### Contributors / 贡献者

| | |
|---|---|
| **arrebel** | Blackwell port, benchmarking, packaging and maintenance（Blackwell 移植、实测、打包与维护） |
| **DeepSeek** | AI-assisted development（AI 辅助开发：代码移植、调试与文档） |

DeepSeek is credited as an assisting tool, not as a copyright holder — the copyright lines in
[LICENSE](LICENSE) are unchanged. Credit for the original codec work remains with mickys.

## Licence

MIT, see [LICENSE](LICENSE). Ported from [mickys/nvenc](https://github.com/mickys/nvenc) (MIT); see [NOTICE](NOTICE) for what came from
where, and for the terms of the driver this plugs into. Unofficial project — not affiliated with NVIDIA,
Apple or NullMoth Systems.
