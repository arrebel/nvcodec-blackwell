# H.264 编解码插件移植记录（Blackwell / RTX 50 系）

**仅供测试**：非官方、实验性插件，无担保、无支持；驱动升级后可能失效，只在一台机器上验证过，
不要用于生产工作流，务必保留软件编解码作为退路。

代码移植自 [mickys/nvenc](https://github.com/mickys/nvenc)（MIT）的 **H.264 部分**。
**只移植、只启用、只验证了 H.264 解码与编码**；`src/` 里其余编解码器源码是未改动的上游基线，
未移植到 Blackwell，也未注册。实机只在 RTX 5070 Ti（GB203）上验证过。

在 nullmoth 的 `NVMTLDriver`（2.7.1 / 1401）之上，用两个自建插件把 **H.264 硬解和硬编**
接进 VideoToolbox，做到和 [mickys/nvenc](https://github.com/mickys/nvenc) 在 40 系上 NVEncVT 一样的效果：
**比苹果的软件实现快，画面/码流正确，可打包安装、可一键还原。**

- `libnvdec_h264.dylib` —— H.264 解码插件（替换驱动自带的同名文件）
- `libnvencvt.dylib` —— H.264 编码插件（驱动本来就留了这个外挂位，`NVMTL_NVENCVT` 控制加载）

## 结果（RTX 5070 Ti / GB203，macOS 15）

| 场景 | 苹果软件实现 | 原厂插件 | **本插件** |
|---|---|---|---|
| 1080p H.264 解码 ×300 帧 | 233–239 fps | 235–239 fps（96% CPU 耗在单线程 `nvd264_detile`） | **696–711 fps** |
| 1080p H.264 编码 ×300 帧 | 77–190 fps | —（50 系没注册任何编码器） | **739–760 fps** |
| 4K H.264 解码 | — | ~180 fps | **229 fps** |
| 4K H.264 编码 ×60 帧 | — | — | **164 fps**（4K60 有 2.7 倍余量） |
| 1080p HEVC 解码 | — | 774 fps | 保持原厂，未改动 |
| 4K HEVC 解码 | — | 206 fps | 保持原厂，未改动 |
| HEVC 编码 | 708 fps（系统编码器） | — | 不接管 |

正确性：

- **解码**：300 帧 I420 与苹果软解逐字节对比 **0 字节差异**（933 MB 全等）。
- **编码**：编码后解码回读与原片比，12 Mbps 下亮度 **PSNR 平均 32.08 dB**
  （同码率苹果软编 28.58 dB），没有错帧。

## 安装

```sh
# 图形化：双击 dist/NVCODEC-Blackwell-1401.pkg
# 命令行：
sudo installer -pkg dist/NVCODEC-Blackwell-1401.pkg -target /
```

安装包做三件事：装入两个插件、把原厂文件备份成 `*.vendor`、在
`/Library/GPUBundles/nvmtl/nvrm610.conf` 里写 `NVMTL_NVENCVT=1`，最后重启
`VTDecoderXPCService`（VideoToolbox 在 XPC 进程里解码，不重启仍会用旧插件）。

### 卸载

```sh
sudo /usr/local/bin/nvdec-uninstall
```

**这里不删文件**：`/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS` 带 SIP 的
`restricted` 标志，root 也不能在该目录里新建、改名或删除文件（只有安装器可以）。所以卸载走配置：

- `NVMTL_NO_NVDEC=1` —— 驱动不注册我们的 H.264 解码插件
- `NVMTL_NVENCVT=0` —— 编码插件自己不注册
- 如果旁边有一份**真正的原厂** `*.vendor`，会先拷回去

还原后 H.264 回到系统实现（解码约 195 fps、画面正常）。想重新启用，重跑安装包即可。

> 已知遗憾：开发过程中一次重复安装把原厂 `libnvdec_h264.dylib` 的备份覆盖成了我们自己的旧版本，
> 这台机器上已经没有原厂文件；要找回它，重装一遍 nullmoth 2.7.1 驱动即可。

## 技术要点

### 1. Blackwell 的显存排布（`src/blocklinear.c`）

50 系的 surface 不是老的 64×8 GOB，而是 **64 字节 × 16 行的 tile**，tile 内是 8×8 像块：
上 8 行的块先排、下 8 行后排。

```
tp = 64/bpp;  br = 8*bpp;
off = (y/16)*pitch*16 + (x/tp)*1024 + ((y%16)/8)*512 + ((x%tp)/8)*64*bpp + (y%8)*br + (x%8)*bpp;
```

配 SSE2 位带拷贝 + 大平面 4 线程的 `bw_untile_plane`：1080p 反平铺 **0.13 ms/帧**（原厂 4.28 ms）。
`dec.c` 按 NVDEC class（≥0xcfb0）自动选布局，`DEC_LAYOUT=kbl|bw` 可覆盖。`hevcdec.c` 里也留过一套
Blackwell 布局实验代码，但自有 HEVC 解码核在 Blackwell 上 P 帧会挂死（引擎不返回），**未启用、未验证**；
HEVC 解码继续用驱动自带的插件。本文件后面提到的 HEVC 条目都是这个状态，不要当成可用功能。

### 2. VideoToolbox 插件 ABI（`src/vtdec.c`、`src/vt/vtnvenc.c`）

- 注册：`VTRegisterVideoDecoderWithInfo(**FourCC** 'avc1', info, create)` —— 第一个参数是编解码器
  FourCC，不是标识符字符串。
- `NVDecH264_CreateInstance(flags, allocator, out)` 是**三参数**。
- `CMDerivedObjectCreate` 的描述符 `{0, d0, d1, {0,1}, 0x98, 0}` 里，**VT 只走 `d0`/`d1` 指向的
  内部署发表**，描述符尾随的函数表根本不会被调用。每项 8 字节：
  `0x14 Invalidate 0x1c Finalize 0x24 CopyDebug 0x2c CopyProperty 0x54 StartSession
  0x5c DecodeFrame 0x64 CopySupportedPropertyDictionary 0x6c SetProperties
  0x74 CopySerializableProperties 0x7c CanAcceptFormatDescription 0x84 FinishDelayedFrames`
- `DecodeFrame(obj, **request**, sampleBuffer, flags, infoFlags)` 的第二个参数必须原样传回
  `VTDecoderSessionEmitDecodedFrame(session, request, status, flags, image)`；传别的（NULL、时间戳、
  sampleBuffer）一律 **-12902**。
- VT **不会**调 `FinishDelayedFrames`，它只死等 `VTDecompressionSessionWaitForAsynchronousFrames`，
  所以每个 sample（一个完整 AU）喂完必须立刻解出并 emit，做到一进一出。
- 出错时不要 emit 空图像（VT 会空指针崩在 0x1a），错误码走 `DecodeFrame` 的返回值。
- **硬件身份要自己申报**：`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` 必须同时在
  `CopySupportedPropertyDictionary` 里声明（Boolean / ReadOnly）并在 `CopyProperty` 里回答，缺一样
  VT 都直接回 `-12900`（它不会去问插件）。少了这一步，一个跑得好好的 NVDEC 会话在诊断工具里
  显示的是“未验证 / 无成绩”，而不是“硬解通过”。`kVTDecompressionPropertyKey_UsingGPURegistryID`
  则由 VT 自己回答（第三方插件申报也没用），所以只会显示“硬解通过 · 设备未报告”。

### 3. 通道层两个真 bug（`src/channel.c`、`src/enc.c`）

- **push buffer 回收**：`chan_rewind` 依赖 USERD 的 `GPGet`，而这页在显存里、这个驱动读回来是 0，
  于是 buffer 一直往后写，约 160 帧（解码）/ 190 帧（编码）后越界 → “no completion” /
  “push buffer not fetched”。改法：解码每帧无条件 `chan_reset_push`（信号量已保证取完）；
  编码按**完成信号量**判断，缓冲区放大到 1 MB、768 KB 处才换行。
- **门铃丢失**：写完 `GPPut`（写合并映射）立刻敲 doorbell，写可能还在合并缓冲里 → 主机读到旧值不取
  命令，约 1/250 帧随机停摆。写完回读该页把写冲出去，等待超时再补敲一次（`chan_kick`）。

### 4. 编码器在 Blackwell 上的差别（`src/vt/vtnvenc.c`）

- 设备识别加 GB20x（PCI id 0x2a00–0x2fff）与 NVENC class `0xcfb7`。
- **没有 NVENC0**（0x1b）：引擎只有 NVENC1（0x1c），打不开就换另一个引擎再试。
- HEVC 编码：我们自己的核在 Blackwell 上会 MMU fault（PDE 缺失，地址高 32 位是垃圾值），所以**不注册**
  （`NVENCVT_HEVC=1` 可以强行试）。驱动 2.7.1 自带的 `libnvenc_hevc.dylib`（注册为
  `com.nvmtl.videoencoder.hevc.nvenc`）在 GB203 上是可用的：1080p 707 fps、4K 171 fps，输出确认是
  真 HEVC（`hvc1`、VPS/SPS/PPS 三个参数集，解回 45 dB PSNR），系统 HEVC 编码不需要我们补。

### 5. 符号可见性

两个插件都只导出入口符号（`NVDecH264_CreateInstance`；`NVEncVT_Register`、`NVEncVT_CreateInstance`）。
早期版本默认导出全部符号，结果**把 HEVC 解码拖到 15 fps**——同进程加载的 HEVC 插件被干扰。
现在用 `-fvisibility=hidden` + `-exported_symbols_list` 双保险。

## 构建

```sh
sh build.sh            # 两个插件 -> build/
sh build.sh all        # 插件 + 验证工具 -> bin/
sh packaging/build-pkg.sh   # -> dist/NVCODEC-Blackwell-1401.pkg
```

需要 NVIDIA 头文件（脚本按 `vendor/` 路径寻找）：

```sh
cd vendor
git clone --depth 1 https://github.com/NVIDIA/open-gpu-doc.git
git clone --depth 1 --filter=blob:none --sparse https://github.com/NVIDIA/open-gpu-kernel-modules.git
cd open-gpu-kernel-modules && git sparse-checkout set src/common/sdk/nvidia/inc src/nvidia/arch/nvalloc/unix/include
```

## 验证工具（`bin/`）

| 工具 | 用途 |
|---|---|
| `vtspeed2 file.mov [帧数]` | 用 `AVAssetReader` 测解码吞吐（真正走 VideoToolbox） |
| `vtenc h264 W H 帧数 [Mbps]` | 测编码吞吐（`VTE_METAL=1` 先建 Metal 设备，驱动插件才会加载） |
| `vtrecode in.mov out.mov [帧数]` | 编码后回读比对 PSNR（`VTRECODE_SW=1` 走苹果软编作对照） |
| `refdump in.mov out.i420 [帧数]` | 导出 I420；`NVMTL_NO_NVDEC=1` 时得到软解基准 |
| `encodeN / decodeN / hevcdecodeN` | 不经 VideoToolbox，直接调用访存层测我们自己的核 |
