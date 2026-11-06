# Open tasks

These tasks are left over from the 2026-11-06 performance work, roughly in priority order. The measurements behind them are in [benchmarks/](benchmarks/), and the harness that produced them is in [benchmarks/harness/](benchmarks/harness/README.md).

## Where things stand

The path from compressed page to Metal texture is close to the limits of the public APIs on iOS. On an iPhone Air, real comic pages reach a finished texture in about 5–15 ms. The hardware JPEG decoder, reached through ImageIO subsampling, is the floor, and the remaining CPU-side cost is copies that ImageIO's API forces.

Real CBZ pages on iPhone Air (iOS 27, Release), decoded from inflated archive bytes. Times are medians of 10 runs.

| Page | Screen | Output | `decode(targetSize:)` | `makeTexture` |
|---|---|---|---:|---:|
| Colour JPEG 975×1349 (1.3 MP, 4:2:0) | iPhone SE | 750×~1030 | 8.6–11.2 ms | 6.0–6.2 ms |
| | Pro Max / iPad (full size) | 975×~1340 | 4.7–5.2 ms | 4.8–5.2 ms |
| Gray JPEG ~1540×2190 (3.4 MP, gray ICC) | iPhone SE | 750×~1070 | 7.9–8.9 ms | 8.0–8.8 ms |
| | Pro Max, `.gray8` (1.16× reduction) | 1320×~1880 | 13.9–14.8 ms | 13.3–13.4 ms |
| | iPad, `.gray8` (full size) | ~1540×2190 | 8.5–8.9 ms | 9.5–9.7 ms |

On small reductions like the Pro Max case, about 4 ms of each page is the GPU Lanczos pass from 3.4 MP. Bilinear was ruled out: the renderer's sampler already provides bilinear quality at draw time.

## 1. GPU-compressed page and thumbnail cache (experiment)

Repeat views and thumbnail grids could skip decoding entirely: decode once, store GPU-native compressed textures, and load them with no decode.

- **Formats:**
  - ASTC on iOS and Apple silicon Macs. 4×4 is 8 bits per pixel; gray pages may tolerate 6×6 or 8×8.
  - EAC R11 for gray pages (single channel, 4 bits per pixel).
  - BC7, or BC4 for gray, on Intel Macs, which support no ASTC or EAC.
- **Encoder:** ImageIO exposes `kCGImagePropertyASTCEncoder`, `kCGImagePropertyASTCBlockSize4x4`/`8x8` and `kCGImagePropertyBCEncoder`. Check what these actually encode and how fast.
- **Mipmaps:** the GPU cannot generate mipmaps for compressed formats, so build the chain at cache time. Resample each level from full resolution with `TextureScaler`'s Lanczos, never from compressed data, then encode each level. A full chain costs about +33% in size.
- **Loading:** use `MTLIOCommandQueue` (`load(_:slice:level:size:...)`). A simple header-plus-levels file, or KTX2, maps onto it directly. For oversized pages, consider Metal sparse textures (Apple's "Streaming large images with Metal sparse textures" sample).
- **Thumbnails:** same-size thumbnails fit in one 2D texture array. At ASTC 4×4, a 200×300 thumbnail is about 60 KB instead of 240 KB.
- **Measure on iPhone:**
  - encode time per page, full mip chain included;
  - file size per format;
  - PSNR against the area-average ground truth at every level, plus a visual check of screentone at intermediate zoom levels;
  - `MTLIOCommandQueue` load time against today's 5–15 ms decodes.
- **Scope:** the library would provide encode and load building blocks. Callers own cache policy, per CLAUDE.md.

## 2. Weakest-device run: 10.5-inch iPad Pro (A10X) — done 2026-11-07

Measured in [benchmarks/2026-11-07-gpu-scale-a10x.md](benchmarks/2026-11-07-gpu-scale-a10x.md). ImageIO stayed 3–7× faster than TurboJPEG at every JPEG size (manga-size decode 18.7 ms vs ~62 ms), `makeTexture` beat `decode(targetSize:)` in every case (up to 2.2× on real pages at small reductions), and MPS Lanczos cost 2–17 ms of GPU time. The iOS routing needs no device-floor exception. `.gray8` halves time and peak memory there, prefetching matters most on that class of device, and the JXL box-filter inversion from task 6 is worse on the A10X.

## 3. Mac TurboJPEG cutoff sweep

`turboJPEGTextureSource` in `ImageSource+Texture.swift` routes JPEGs of 12 MP or less to TurboJPEG on Mac and Catalyst. The cutoff is a guess: TurboJPEG won at 6.6 MP and lost at 50 MP on the M4 Max. Use the macOS harness with generated pages at about 8, 12, 16, 24 and 36 MP, for colour and gray, then set the cutoff from the measured crossover. Also try an Intel Mac if one is available.

## 4. Rotated JPEGs

EXIF-rotated JPEGs skip both the subsampled decode for 4× or greater reductions (`imageIOSubsampledImage` returns nil for `orientation != .up`) and `makeTexture`'s native path. A plain image decode does not apply EXIF transforms, so apply the orientation in the existing CoreGraphics render pass, or in the GPU resample. Comics rarely carry orientation; photos often do. `testAllEXIFOrientationsHaveConsistentPixelsAndCropCoordinates` covers the contract.

## 5. `cropRect` in `makeTexture`

Zooming into oversized pages still uses `decode(cropRect:)` on the CPU. A `cropRect` parameter could use TurboJPEG's cropped decode (`JPEGRegionDecoder`) and then the GPU resample. Note that iOS crops currently rely on TurboJPEG or a full ImageIO decode, so measure against the hardware full decode first.

## 6. JXL box filter vs full decode

At manga size, the JXL 2×/4× box-filtered thumbnail is slower than a full decode plus GPU resample: 46.7 vs 31.9 ms on iPhone Air, and about 24 vs 18 ms on the Mac. The box filter exists to avoid a full-resolution bitmap. Switch to full decode when the full-size bitmap fits a memory budget, for example using `estimatedDecodeMemory`.

Confirmed on the A10X (2026-11-07, [write-up](benchmarks/2026-11-07-gpu-scale-a10x.md)): 207 vs 141–159 ms at manga size with a 2.4 dB quality gap, and every downsampled libjxl decode measured there cost more than decoding in full. Only oversized sources still need the filter, for memory (180 MB boxed vs 484 MB full on the 121 MP fixture), which is the budget boundary.

## 7. Dependency upgrades

These were reviewed on 2026-11-06 and deferred.

- **libjxl 0.12.0:** its speedups are mostly for modular (lossless) decoding; VarDCT pages gained about 1.3% in September. Benchmark a lossless page with 0.11.2 and 0.12 before releasing libjxl-cocoa 0.12.
- **libjpeg-turbo 3.2.1 or 3.1.4.1:** bug and security fixes only, with no usable decode features. The ICC fix in `JPEGRegionDecoder` handles both the 3.1 and 3.2 `tj3GetICCProfile` behaviour. 3.2 bundles zlib and libspng, so check binary size.

## App-side recommendations (not library work)

- **Memory admission:** cap concurrent decodes with `estimatedDecodeMemory`, so several oversized pages cannot spike at once.
- **Archives:** `ImageSource(data:)` is zero-copy, including slices, so stored CBZ entries can be decoded straight from a memory-mapped archive (see the README). Deflated entries must be inflated first, at about 0.5–1.7 ms per page. Only map archives in your own container; truncation while mapped crashes the app.
- **Gray pages:** use `.gray8` for grayscale pages (`colorModel == .grayscale`). It is the fastest path and uses a quarter of the texture memory.
- **Prefetching:** decode the next pages in the background; every measured page fits within one or two 60 Hz frames.

## Measured and rejected (don't redo without new information)

| Idea | Result |
|---|---|
| vImage / Accelerate resampling | Slower than CoreGraphics (measured before 2026-11-06). |
| Direct upload of ImageIO's bitmap | `dataProvider.data` is itself a copy (7.6 ms per 30 MB); 2–5 ms saved, within noise. |
| Core Image Lanczos for `makeTexture` | 12 ms faster only on 11000² pages; −5 dB at 5000×10000 → 512×1024 for unknown reasons. |
| VideoToolbox Motion-JPEG | Hardware, zero-copy (`420f` IOSurface), about 2 Gpx/s, but no reduced-resolution decode (`-12900`). It loses on oversized pages and ignores EXIF and ICC. |
| Private APIs | App Store risk; at best about 15% on the largest pages. |
| Porting a GPU JPEG decoder | nvJPEG is closed source, and entropy decoding is serial; the A19 Pro's GPU would likely lose to the hardware decoder. |
| A custom SIMD JPEG decoder | libjpeg-turbo already is one and loses to the hardware decoder by 4×. |
| Bilinear instead of Lanczos | Renderer sampling already gives bilinear quality. |

Details are in the iPhone write-up's follow-up sections: [benchmarks/2026-11-06-gpu-scale-iphone.md](benchmarks/2026-11-06-gpu-scale-iphone.md).

## Environment notes

- **LFS:** test sample images live in Git LFS. Run `git lfs pull`, or tests that use `SampleImages` crash on pointer files. CI fetches LFS objects with a cache.
- **Simulator:** it cannot create linear textures on shared buffers, so `withMetalStorage` is a no-op there and simulator builds use the copy upload.
- **Device timings:** run with Auto-Lock off and allow cooldown between runs. libjxl decode times vary by ±10 ms between runs, so compare stage timings, or interleave A and B in one process.
