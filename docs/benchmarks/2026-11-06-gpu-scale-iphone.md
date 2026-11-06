# GPU downscaling on iPhone Air — 2026-11-06

This is a device follow-up to the [Mac run](2026-11-06-gpu-scale.md). It uses the same probe, fixtures, pipelines and ground truth, on an iPhone Air (iPhone18,4: A19 Pro, 6 cores, 12 GB) running iOS 27.0.1. The build is Release, from library sources at `c8332b2`, with libjpeg-turbo 3.1.3 and libjxl 0.11.2. Seven timed runs per case after one warm-up; tables report medians.

## Method differences from the Mac run

- `xcodebuild` test launches fail from this agent environment with "Pseudo Terminal Setup Error", on both simulators and devices. So the probe ran inside a temporary copy of the example app instead: `ViewController` runs the benchmark on a background thread and exits, and `devicectl device process launch --console` captured stdout. Fixtures from the Mac run were bundled as a `ProbeFixtures` folder resource.
- The first launch ran every fixture until the untagged gray JPEG. `JPEGRegionDecoder` now deliberately refuses untagged grayscale, which `ImageSource` sends to ImageIO. For a second launch, the temporary copy let gray through as sRGB, so the TurboJPEG rows time the decoder only; those colours would not match ImageIO. Only the manga fixtures ran in the second launch, after a 60-second cooldown.
- Thermal state reached 1 (fair) during the 11000² JXL cases and was 0 (nominal) for everything else.

## Results (bound 2048)

| Fixture | Pipeline | Wall ms | CPU ms | Resample stage | GPU ms | Truth dB |
|---|---|---:|---:|---:|---:|---:|
| JPEG 11000² → 2047² | `current` | 91.0 | 54.0 | (in decode) | | 30.7 |
| | `native+CG` | 250.4 | 250.2 | 17.5 | | 30.8 |
| | `native+lanczos` | 235.3 | 224.8 | 11.3 | 9.8 | 36.5 |
| | `imageio-subsample+lanczos` | **71.4** | **25.2** | 11.6 | 9.5 | **36.5** |
| JXL 11000² → 2047² | `current` | 719.2 | 3668 | (in decode) | | 30.7 |
| | `native+CG` | 748.7 | 3762 | **77.3** | | 30.7 |
| | `native+lanczos` | 699.0 | 3793 | 11.2 | 9.5 | **36.5** |
| JPEG 5000×10000 → 1024×2048 | `current` | 41.6 | 22.8 | (in decode) | | 26.2 |
| | `native+lanczos` | 145.6 | 141.3 | 4.9 | 3.6 | 28.2 |
| | `imageio-subsample+lanczos` | **31.8** | **10.2** | 5.2 | 3.6 | **28.1** |
| Gray JPEG 2160×3072 → 1440×2048 | `current` | 17.5 | 14.7 | (in decode) | | 27.8 |
| | `native+CG` | 31.9 | 31.9 | 9.9 | | 28.2 |
| | `native+lanczos` | 29.6 | 24.1 | 6.2 | 5.0 | 28.3 |
| | `imageio-subsample+lanczos` | **8.5** | **3.5** | 2.5 | 2.0 | **30.1** |
| Gray JXL 2160×3072 → 1440×2048 | `current` | 46.5 | 168.9 | (in decode) | | 27.7 |
| | `native+CG` | 46.1 | 171.6 | 13.1 | | 27.7 |
| | `native+lanczos` | 40.6 | 158.1 | 6.6 | 5.5 | **30.1** |
| | `native+bilinear` | **37.8** | 160.9 | 3.2 | 1.7 | 32.2 |

The 1024 bound, `current-gray8`, the native-gray JXL pipelines and per-run values are in [2026-11-06-gpu-scale-iphone-results.log](2026-11-06-gpu-scale-iphone-results.log).

## Findings

- **On iPhone, ImageIO beats TurboJPEG for every JPEG tested.** The Mac's finding that TurboJPEG wins on manga-sized pages does not hold on device. ImageIO decoded the 6.6 MP gray page at 1/2 subsampling in 4.8 ms, against 20.8 ms for TurboJPEG's 6/8 DCT-scaled decode. Wall time far exceeds CPU time at every size, which suggests the hardware decoder.
- **ImageIO subsample plus GPU Lanczos was the best JPEG pipeline in every case.** It was 22–51% faster than `current`, used about half the CPU or less, and scored 1.9–5.8 dB closer to the true downscale. For the gray manga JPEG, a full page took 8.5 ms instead of 17.5 ms.
- **ImageIO's iOS thumbnails lose quality at small sizes.** For 5000×10000 → 512×1024, `current` scored 18.2 dB, against 22.8–23.5 dB for every explicitly resampled pipeline (the Mac scored 23.5 dB). It is fast (27 ms) because it appears to skip proper filtering, so expect visible aliasing on screentone.
- **Lanczos takes real GPU time on the A19 Pro, but less than CG takes on the CPU.** Lanczos GPU time was 1.3–9.8 ms (Mac: 0.5–2.4 ms), against 2–77 ms of CPU for CG. Bilinear is 0.3–2.1 ms but less consistent in quality. In a real reader, the GPU wait would overlap other work rather than block a thread as it does here.
- **CG is about 4× slower on RGB JXL output than on JPEG output of the same size** (77.3 ms vs 17.5 ms for 2750² → 2047²; Mac 56.8 vs 15.1 ms). The JXL buffer's colour space is libjxl's generated sRGB ICC profile, which is not equal to `kCGColorSpaceSRGB`, so CG colour-matches every draw and `finish()` never takes its no-render path. The gray JXL avoids this because its gray profile is rejected in favour of the default sRGB. Mapping libjxl's encoded sRGB colour to the named sRGB space should remove most of that cost from the shipped CPU path.
- **JXL is decode-bound on the phone.** The 11000² photo takes about 700 ms and 3.7 s of CPU across 6 cores; the gray manga page takes about 31 ms to decode at full size. Moving the resample to the GPU saves 6–66 ms per page.
- **The 2×2/4×4 box-filtered JXL path is slower than a full decode at manga size** (46.7 vs 31.9 ms on iPhone; the Mac showed a similar ratio). The box filter trades time for not allocating a full-resolution bitmap, and this predates today's grayscale change. A same-session Mac A/B run of the old and new decoder measured 32.4 vs 31.2 ms (manga) and 422 vs 358 ms (11000²). For pages whose full-size bitmap fits the memory budget, a full decode plus a GPU resample is faster.

## Not covered

- Crops and region decodes. TurboJPEG's cropped decode avoids the full decode that ImageIO's crop path needs, and remains the expected choice for zooming into oversized pages.
- Lossless JXL, PNG, WebP and AVIF.
- Older devices. Re-run on the 10.5-inch iPad Pro (A10X) before making routing decisions that depend on hardware decode behaviour.

## Follow-up: subsampled JPEG decoding for large reductions

`decode(targetSize:)` and `makeThumbnail(fittingSize:)` now handle upright JPEGs reduced by 4× or more differently. Instead of using ImageIO's thumbnail resampling, they decode at ImageIO's 1/4 or 1/8 subsample factor and resample once with CoreGraphics. A rerun of the JPEG fixtures with this change ([log](2026-11-06-gpu-scale-iphone-subsample-results.log)) shows that the `current` pipeline now uses this path:

| JPEG case | Before: ms / truth dB | After: ms / truth dB |
|---|---|---|
| 5000×10000 → 512×1024 | 27.3 / 18.2 | 24.6 / 22.6 |
| 5000×10000 → 1024×2048 | 41.6 / 26.2 | 32.8 / 26.2 |
| 11000² → 2047² | 91.0 / 30.7 | 73.3 / 30.7 |
| 11000² → 1023² | 55.0 / 27.3 | 50.1 / 27.3 |

The aliasing at large reductions is mostly gone; TurboJPEG + CG still scores 23.5 dB on the first row. Every case got faster. At 2–4× reductions (gray manga → 720×1024), ImageIO's thumbnail scored the same quality and was about 1 ms faster, so those keep the thumbnail path. On the M4 Max, the same JPEG cases were 5–15% faster with identical quality.

## Follow-up: the `makeTexture(fitting:pixelFormat:using:)` API

This run timed the public API end to end, including the `await` ([log](2026-11-06-gpu-scale-iphone-texture-api-results.log)). `current` already includes the subsampled JPEG decoding above. All MPS kernels in this run, both the library's and the probe's, clamp at the edges. Earlier GPU rows used the default `.zero` edge mode, which blends transparent black into border pixels; that affects only borders, so the earlier conclusions stand. Thermal state was 1 (fair) from the 5000×10000 cases onward.

| Fixture → bound 2048 / 1024 | `current` ms (truth dB) | `makeTexture` ms (truth dB) |
|---|---|---|
| JPEG 11000² | 71.3 (30.7) / 51.7 (27.3) | 74.5 (36.5) / 58.4 (31.3) |
| JPEG 5000×10000 | 32.8 (26.2) / 24.2 (22.6) | 32.8 (28.1) / 24.8 (22.8) |
| Gray JPEG, `.gray8` | 15.3 (27.8) / 7.9 (24.7) | 9.8 (30.1) / 6.2 (27.5) |
| Gray JXL, `.gray8` | 48.7 (27.7) / 66.4 (24.7) | 44.6 (30.1) / 61.5 (27.4) |

For RGBA output, the API now has about the same latency as the CPU path: within 0–13% (up to 7 ms), mostly because the subsampled-decode fix sped up the CPU path. Its gains are quality (+0.2 to +5.8 dB) and lower CPU time on JPEG. Grayscale output is faster, at 7–36% less latency with +2.4 to +2.8 dB. RGB JXL stays decode-bound.

## Follow-up: avoiding the CPU copies in `makeTexture` (not adopted)

The JPEG path in `makeTexture` copies ImageIO's subsampled bitmap through CoreGraphics and then uploads it with `replace(region:)`. Three alternatives were measured on the iPhone ([log](2026-11-06-gpu-scale-iphone-copy-avoidance.log)).

What ImageIO returns on iOS: RGB JPEGs come back as 32-bit RGBX (`noneSkipLast`) tagged sRGB, with every sampled skip byte set to 255. Gray JPEGs come back as 8-bit Generic Gray Gamma 2.2. The CoreGraphics copy changed no values (maximum difference 0 for RGB, gray8 and gray-to-RGBA). Reading the bitmap through `dataProvider.data` is itself a copy (7.6 ms for 30 MB). Row strides such as 11000 bytes are not 16-byte aligned, so ImageIO's buffer cannot back a linear texture. MPS does honour texture-view swizzles, so a view can force the skip byte to opaque alpha.

| Page | `makeTexture` | Core Image (edge-clamped Lanczos) | Direct upload |
|---|---|---|---|
| 11000² → 2047² | 72.7 ms, 36.5 dB | 60.5 ms, 36.6 dB | 73.8 ms |
| 11000² → 1023² | 55.4 ms, 31.3 dB | 50.5 ms, 31.3 dB | 56.3 ms |
| 5000×10000 → 1024×2048 | 32.1 ms, 28.1 dB | 31.5 ms, 28.2 dB | 40.9 ms |
| 5000×10000 → 512×1024 | 24.6 ms, 22.8 dB | 29.2 ms, 17.6 dB | 32.9 ms |

Neither alternative was adopted. Direct upload saves 2–5 ms in isolation, which is within run-to-run noise end to end, because reading ImageIO's bytes is a copy of its own. Core Image saves 12 ms only on the largest page and is roughly even elsewhere. It also loses 5 dB at 5000×10000 → 512×1024, for unknown reasons, and would add a second resampler and colour pipeline. On the largest page, `makeTexture` is within about 25 ms of ImageIO's subsampled hardware decode alone (46 ms); on the other pages it is within a few milliseconds.
