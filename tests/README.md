# tests

The VideoToolbox harnesses behind the numbers in the README. `sh build.sh tools` puts the binaries in
`build/`. They need their own input; nothing here ships a clip.

Generate a clip with `vtgen` (Apple's software encoder, 1080p / 4K, H.264 or HEVC):

```sh
./build/vtgen out.mov 1920 1080 120 h264      # see vtgen.m for the options it takes
```

| tool | what it answers | example |
|---|---|---|
| `vtprops3` | What does a forced-hardware decode session claim about itself, and how fast does it decode? Registers the plug-in dylib in-process, so it works without installing anything. | `./build/vtprops3 build/libnvdec_h264.dylib` |
| `vtplugtest` | Loads a decoder dylib the way the driver does and decodes a movie through AVFoundation. | `./build/vtplugtest build/libnvdec_h264.dylib clip.mov 300` |
| `vtspeed2` | Playback-style throughput: AVAssetReader + NV12 output settings, counts frames, not pixels. | `./build/vtspeed2 clip.mov 300` |
| `vtbench` | Encodes a stream with Apple's software encoder, then decodes it three ways (software, allow-hardware, require-hardware) and prints fps and whether the session reports hardware. | `./build/vtbench` |
| `vtenc` | Encoder throughput; `VTE_SW=1` for the software baseline, `VTE_METAL=1` to make the driver load its plug-ins first. | `./build/vtenc hevc 1920 1080 120 8` |
| `hevcchk` | Encodes, then decodes its own output back and reports PSNR — catches an encoder that “works” by producing garbage. | `./build/hevcchk hevc 60` |
| `vtrecode` | Encode a real clip, decode it back, PSNR per frame. | `./build/vtrecode in.mov out.mov 120 8` |
| `enclist` | Which encoders VideoToolbox knows, and which claim hardware. | `./build/enclist` |
| `extract`, `refdump`, `vtimg` | Annex-B extraction, raw I420 reference dump, single-frame PNG for eyeballing a decode. | see the sources |

Two notes that cost time to learn:

- **A sample buffer from `AVAssetReader` with output settings is already decoded.** Handing it to a
  `VTDecompressionSession` you created yourself returns `-12916`
  (`kVTFormatDescriptionChangeNotSupportedErr`). To time a session you own, feed it compressed samples —
  that is what `vtbench` and `vtprops3` do.
- **Back-to-back runs destabilise the driver.** After several full matrices in a row, session creation
  starts failing with `-12913` / `-12903` — including for the stock HEVC decoder, so it is not this
  plug-in. Reboot before re-measuring; one clean run is the number to trust.
