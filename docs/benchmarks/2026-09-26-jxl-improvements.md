# JPEG XL thumbnail improvements on iPad Pro

Follow-up to the [oversized-image baseline](2026-09-26-ipad-pro.md), using the same 10.5-inch iPad Pro on iPadOS 17.7.11 and the same 11000×11000 VarDCT JXL fixture.

## Production change

JXLDecoder now averages 2×2 or 4×4 blocks in the final output callbacks when the requested thumbnail is larger than the DC preview. For the 2048-pixel request, it accumulates a 2750×2750 intermediate image and then resizes to the final 2047×2047 buffer. It no longer allocates the 11000×11000 RGBA output bitmap for this case. Full codec detail still has to be decoded; this is an output-memory optimization, not native reduced-resolution decoding.

The accumulator holds four UInt16 channel sums per intermediate pixel and locks individual destination rows to accept concurrent, fragmented callbacks. Alpha is premultiplied before filtering; partial edge boxes use their actual sample counts. Orientation and RGB color profiles remain intact. DC preview decoding is unchanged. Requests too large for 2× reduction still use full-size output. Codec working storage can remain proportional to source dimensions, so memory estimates retain their conservative allowance.

## Measurements

Six separately loaded compressed inputs, six retained output PixelBuffers, Release build, code coverage disabled. Times below are **whole six-page batches**, not per-image latency. Physical footprint includes the test host, compressed inputs, retained outputs, and codec working allocations. The sampler runs every 5 ms and can miss short spikes.

Each row is one exploratory batch, not a median or confidence interval. All rows were nominal thermal state unless indicated. The original one-worker implementation was rerun under nominal conditions to make the before/after comparison more useful than the earlier fair-temperature matrix.

| Decoder | Requested bound | Concurrent pages | Batch seconds | Peak process MiB |
|---|---:|---:|---:|---:|
| Original libjxl 0.11.2 | 2048 | 1 | 30.41 | 763.2 |
| Filtered libjxl 0.11.2 | 2048 | 1 | 16.47 | 387.3 |
| Filtered libjxl 0.11.2 | 2048 | 2 | 13.99 | 586.3 |
| Filtered libjxl 0.11.2 | 2048 | 3 | 11.00 | 815.9 |
| Apple ImageIO | 2048 | 1 | 14.36 | 824.8 |
| Apple ImageIO | 1024 | 1 | 11.63 | 740.7 |
| Filtered local libjxl 0.12.0 | 2048 | 1 | 12.06 | 388.4 |
| Filtered local libjxl 0.12.0 | 2048 | 2 | 11.90 | 616.0 |
| DC local libjxl 0.12.0 | 1024 | 1 | 11.03 | 248.4 |

The production change reduced measured one-worker batch time by 46% and peak process memory by 49%. Three workers offer more throughput at about 816 MiB observed peak, but the rest of the comic app still needs memory headroom. One worker provides the lowest measured peak.

Apple ImageIO was tested through CGImageSourceCreateThumbnailAtIndex with source caching disabled, thumbnail creation forced, orientation applied, and the maximum dimension set to the requested bound. The result was rendered into RGBA. It returns exact 2048/1024 dimensions; the library currently returns 2047/1023 because of existing floating-point flooring. Apple's modest speed advantage over filtered 0.11.2 came with more than twice the one-worker peak footprint at 2048, so the library keeps its libjxl path.

The local 0.12.0 one-worker result was 27% faster than filtered 0.11.2 at similar peak memory. The two-worker 0.12 batch started nominal and ended fair; its DC batch ran fair throughout. These results suggest investigating a dependency upgrade, but they do not isolate upstream version changes from compiler/build differences. The 0.11.2 framework is the published dependency; 0.12.0 was built locally with Xcode 27 beta. No 0.12 binary is added to this repository and the production dependency remains 0.11.2.

## Quality and correctness

The oversized photo was compared against a full libjxl decode followed by Core Graphics high-quality resizing to the same 2047×2047 output. RGB mean absolute error was 1.62 out of 255; PSNR was 36.83 dB. Both exported PNGs were visually inspected and showed no obvious structural or color artifacts. The filter is not pixel-identical to a full-decode resize, and one photo does not establish quality for fine comic lettering or every coding mode.

Regression tests cover factor-2 and factor-4 reduction of a checkerboard, partial right/bottom boxes, transparent colors, premultiplied and unassociated alpha, all eight orientations, concurrent fragmented rows, and Display P3 profile preservation. The original implementation failed the new reduced-output and edge tests before the implementation change.

Final verification: all **148 tests passed** in the Swift 6 Release package on the iOS 18.5 simulator. The complete Release suite on the physical iPad ran **148 tests with one pre-existing failure**: `testTransparentJXLPremultipliesBothFullAndThumbnailOutput` fails when ImageSource asks iPadOS 17 ImageIO for metadata for the 29-byte synthetic unassociated-alpha JXL. Direct libjxl checks pass, and this is the same failure recorded before the optimization. All five new tests passed on the device. The normal example app was restored by this final test run. Independent code review found no blocking correctness or concurrency issues; its suggested factor-2 and wide-gamut coverage was added before final verification.

## Upstream and build experiment

[Upstream shrink-on-load issue #4297](https://github.com/libjxl/libjxl/issues/4297) remains the relevant limitation. Callback resampling avoids retaining a full output bitmap without changing the codec's decoding work. [libjxl 0.12.0](https://github.com/libjxl/libjxl/releases/tag/v0.12.0) does not supply a general target-size decode API.

The temporary source checkout is `/tmp/ImageIOKit-libjxl-0.12`, built with CMake/Ninja for arm64 iPhoneOS, deployment target 16.0, Release, static libraries, skcms, JPEG reconstruction and boxes enabled. Tools, tests, examples, plugins, viewers, optional OpenEXR/sjpeg, and tcmalloc were disabled. Targets `jxl` and `jxl_threads` plus their static dependencies were combined into a temporary XCFramework at `/tmp/ImageIOKit-jxl012-package/jxl.xcframework`. The temporary Xcode project substituted that local package for libjxl-cocoa. Runtime JxlDecoderVersion printed 12000, confirming the tested binary.

## Evidence

- [Raw measurements](2026-09-26-jxl-improvements-results.json) preserve seconds and byte counts.
- `/tmp/ImageIOKit-iPad-probe/jxl-matched-baseline.log` and `.xcresult`: original implementation, nominal temperature.
- `/tmp/ImageIOKit-iPad-probe/filtered-jxl.log` and `.xcresult`: filtered one/two-worker measurements.
- `/tmp/ImageIOKit-iPad-probe/filtered-quality.log` and `.xcresult`: three workers, initial four regressions, quality comparison and PNG attachments.
- `/tmp/ImageIOKit-jxl-quality-images`: exported reference and filtered PNGs with a manifest.
- `/tmp/ImageIOKit-iPad-probe/apple-jxl.log` and `.xcresult`: Apple ImageIO comparison.
- `/tmp/ImageIOKit-iPad-probe012/filtered012.log` and `.xcresult`: local libjxl 0.12.0 comparison, all three cases passed.
- `/tmp/ImageIOKit-jxl012-build.log`: local native build.
- `/tmp/ImageIOKit-JXL-package-final.log`: final actual-package suite, 148 passed.
- `/tmp/ImageIOKit-iPad-jxl-final.log` and `.xcresult`: final physical-device suite, 147 passed and the existing metadata failure reproduced.

The temporary probe harness remains in `/tmp/ImageIOKit-iPad-probe/ImageIOKitTests/MemoryTrackingTests.swift`; fixtures and probe binaries are not part of the production library. These measurements are specific to the fixture, device and OS, and do not promise a fixed memory ceiling for arbitrary JXL files.
