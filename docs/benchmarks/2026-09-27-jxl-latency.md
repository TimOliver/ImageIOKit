# JXL output-buffer reuse and thread scheduling

Follow-up to the [real-comic benchmark](2026-09-27-real-jxl.md), using the same private samples and 10.5-inch iPad Pro on iPadOS 17.7.11. The published libjxl version remains 0.11.2.

## Result and production decision

The raw JXL thumbnail path now reuses an already-fitted sRGB RGBA PixelBuffer when its size and layout match the requested output. A regular 2160×3072 page fitted to 1440×2048 allocates **36.56 MiB of PixelBuffer storage instead of 47.81 MiB**, avoiding one 11.25 MiB output allocation and redraw. These are cumulative buffer-allocation bytes, not process peak memory. Measured peak footprint remains essentially unchanged because codec working storage dominates.

There was no consistent per-page latency improvement from buffer reuse alone. The alternative resizable runner was modestly faster in this device sample, around 1–2% versus the previous path in the final regular-page, two-worker batch and oversized comparisons. That limited benefit does not justify changing the default across all devices from this probe alone. Production keeps the existing fixed runner and its default worker count. No new public options or dependency changes were introduced.

Existing fitting and colour conversion are preserved. Some aspect ratios round to a slightly different inner thumbnail size before the final requested size; these still need the second resize. Wide-gamut JXL continues to normalize through sRGB RGBA before conversion to grayscale. Removing those stages changed pixels, so focused regression tests were added and the implementation narrowed to skip only compatible-buffer redraws.

## Method

The temporary Release test host disables its normal delayed decode. Inputs are loaded Data; each operation creates a fresh ImageSource. The previous route is reproduced by making the same ImageIOKit thumbnail and rendering it into the requested final buffer. Every final single-page and oversized result is compared byte-for-byte with that route. There are five repetitions for each of six pages and each configuration, three repetitions per six-page batch/worker count, and three oversized repetitions. Configuration order rotates between iterations. All retained measurements below were recorded at nominal thermal state.

Physical footprint is sampled every 5 ms and at operation completion. It includes the host, inputs, reference pixels and codec storage, and can miss short spikes. A temporary counter records every PixelBuffer allocation; it does not count libjxl internal allocations, box-filter sums, allocator overhead or GPU storage. Instrumentation and runner controls exist only in the temporary probe. Archive extraction, input loading, GPU upload and reader UI work are excluded.

## Matched final comparison

Times are mean milliseconds per image. The three timing columns use the same final implementation except for the retained previous rendering route and temporary runner selection.

| Private sample | Previous path | Buffer reuse | Buffer reuse + resizable 3 |
|---|---:|---:|---:|
| Colour cover | 125.8 | 125.4 | 121.3 |
| Regular page A | 160.7 | 163.0 | 159.6 |
| Regular page B | 155.3 | 157.5 | 153.2 |
| Regular page C | 165.0 | 168.9 | 161.7 |
| Grayscale spread | 325.7 | 325.9 | 324.8 |
| Colour spread | 286.8 | 288.0 | 285.4 |
| Mean of regular pages | 160.3 | 163.1 | 158.2 |

Buffer reuse alone was a few milliseconds faster in the initial screen and a few milliseconds slower in this confirmation. That is insufficient evidence for a dependable latency improvement. The deterministic benefit is the avoided allocation and redraw. Both spreads retain the necessary second resize and therefore allocate the same pixel-buffer bytes as before.

| Configuration | Concurrent pages | Median six-page batch seconds | Mean active page latency ms | Maximum sampled process MiB |
|---|---:|---:|---:|---:|
| Previous path | 1 | 1.223 | 203.5 | 127.6 |
| Previous path | 2 | 0.877 | 287.7 | 170.7 |
| Previous path | 3 | 0.902 | 378.3 | 176.5 |
| Buffer reuse, existing runner | 1 | 1.198 | 200.1 | 127.6 |
| Buffer reuse, existing runner | 2 | 0.877 | 287.6 | 170.6 |
| Buffer reuse, existing runner | 3 | 0.887 | 373.2 | 180.7 |
| Buffer reuse, resizable runner (3 threads) | 1 | 1.197 | 200.1 | 127.5 |
| Buffer reuse, resizable runner (3 threads) | 2 | 0.863 | 283.4 | 170.6 |
| Buffer reuse, resizable runner (3 threads) | 3 | 0.871 | 369.0 | 172.8 |

Batch timings retain all six outputs; active page latency excludes waiting before a worker starts. Three workers still offer little throughput benefit over two and increase individual-page latency. Peak differences between batch repetitions are not a fixed memory guarantee.

## Thread-count screening

A preliminary screen exercised seven configurations. Only the three regular-page cases are retained here: those pixels matched the reference and all their runs were nominal. The preliminary broader direct-render prototype changed spread sampling; those spread and batch results are excluded, and the corrected final comparison above covers all six pages.

| Runner setting | Mean regular-page decode ms |
|---|---:|
| `legacy_default` | 164.1 |
| `direct_default` | 160.1 |
| `direct_fixed0` | 321.3 |
| `direct_fixed1` | 328.9 |
| `direct_fixed2` | 202.4 |
| `direct_resize2` | 199.8 |
| `direct_resize3` | 157.1 |

The default fixed runner reports three worker threads on this iPad. `fixed0` uses only the calling thread; `fixed1` has one worker; `fixed2` has two. The resizable count includes the calling thread, so `resize3` uses two workers plus the caller. Reducing parallel work approximately doubled single-page time with one active decode thread, and two active threads were still slower than three. The two runner implementations should not be compared by background-thread count alone.

## Oversized check

The existing 11000×11000 photo fixture was fitted to 2047×2047. All nine outputs matched the previous route byte-for-byte. These are single-image measurements with a retained reference, not directly comparable to the earlier six-image oversized batches.

| Configuration | Mean seconds | Cumulative PixelBuffer MiB | Maximum sampled process MiB |
|---|---:|---:|---:|
| Previous path | 1.865 | 60.82 | 285.3 |
| Buffer reuse, existing runner | 1.869 | 44.83 | 285.3 |
| Buffer reuse, resizable runner (3 threads) | 1.845 | 44.83 | 285.2 |

Buffer reuse eliminates a 15.98 MiB output allocation for this case. It does not reduce the codec working-memory requirement.

## Verification and reproduction

- All **156 Swift 6 Release package tests passed** on the iOS 18.5 simulator.
- The final device matrix passed all three tests, including the allocation budget and byte comparisons.
- The device regression/oversized run executed 23 tests: 22 passed and one was skipped because iOS 17 ImageIO could not read the synthetic alpha/orientation fixture metadata. The pre-existing `testTransparentJXLPremultipliesBothFullAndThumbnailOutput` metadata failure was excluded explicitly; it was unresolved in this benchmark revision. The new rounding and grayscale tests passed on the device.
- The rounding and Display P3 grayscale regressions failed against the overly broad prototype before the compatibility fix. Independent review found no remaining issues.
- [Raw measurements](2026-09-27-jxl-latency-results.json), [standalone probe](2026-09-27-jxl-latency-probe.swift), and [temporary instrumentation patch](2026-09-27-jxl-latency-instrumentation.patch) contain no comic titles, source filenames or artwork.
- Reproduce using a separate copy of the example Xcode project. Apply the instrumentation patch with `git apply --unidiff-zero` only to that temporary copy, and replace its MemoryTrackingTests.swift with the standalone probe. The patch exposes rendering helpers to the test target, adds cumulative allocation accounting, and permits sequential selection of the runner for each probe configuration.
- Add the six private images under neutral names `page000.jxl`, `page003.jxl`, `page056.jxl`, `page117.jxl`, `page012.jxl`, `page013.jxl`, plus the oversized fixture as `large.jxl`, in a `ProbeFixtures` folder resource. Disable the normal example-controller decode and keep the device awake.
- Run scheme `ImageIOKitTests` in Release with `-parallel-testing-enabled NO`, `-enableCodeCoverage NO`, `ENABLE_TESTABILITY=YES`, selecting `MemoryTrackingTests`. The standalone probe contains the three final configurations; additional screening counts can be added to its configuration list.
- The normal example app was rebuilt and restored on the iPad after testing.
- Local evidence: `/tmp/ImageIOKit-jxl-latency-probe/confirmation.log` and `.xcresult`, `large-and-regressions.log` and `.xcresult`, and `/tmp/ImageIOKit-jxl-latency-package-final.log`. The initial allocation failure is in `allocation-before.log`; compatibility failures are in `/tmp/ImageIOKit-jxl-latency-compatibility-red.log`.
