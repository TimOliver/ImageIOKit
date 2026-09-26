# Downsampled disk cache on the 10.5-inch iPad Pro

Tested on iPadOS 17.7.11 in Release with coverage disabled, using five publisher-provided JPEG pages from a private comic archive. Images remain local and are not included in this repository.

## What changed

`PixelBuffer.write(to:as:quality:)` writes already-decoded pixels through ImageIO, with quality 0.95 as the default chosen after this benchmark. The existing optimized decode can supply both the displayed image and the disk cache without decoding the original twice. The writer retains color profiles, preserves PNG alpha, composites JPEG transparency over black, and atomically replaces a completed cache entry using a temporary file in the destination directory. It is synchronous and leaves scheduling, naming, eviction and cache directory creation to the caller.

```swift
let pixels = try source.decode(targetSize: CGSize(width: 2048, height: 2048))
try pixels.write(to: cacheURL, as: .jpeg, quality: 0.95)
// For lossless compression of those downsampled pixels:
try pixels.write(to: pngCacheURL, as: .png)
```

The older `ImageSource.writeConditionedJPEG` still has its existing ImageIO-based general conversion path; use the buffer writer to reuse the optimized JXL/WebP decode or pixels already prepared for display.

## Archive and selection

The archive has 291 JPEG pages totalling 2,624,420,987 compressed image bytes. Of these, 237 are 9675×14513. Five cases were selected to cover colour, fine manga detail, ordinary file size and extreme dimensions:

| Page | Content / reason | Source pixels | Source MB |
|---|---|---:|---:|
| 001 | Colour cover | 7405×11108 | 3.42 |
| 015 | Largest JPEG file; detailed manga page | 9525×14288 | 23.00 |
| 151 | Another large manga JPEG | 9675×14513 | 21.78 |
| 170 | Median compressed file size | 9675×14513 | 8.92 |
| 281 | Largest dimensions; dense translation notes | 12000×18000 | 6.46 |

All five fit to 1365×2048 pixels. Each RGBA buffer occupies 10.66 MiB. The originals would require approximately 519 MiB for page 15 and 824 MiB for page 281 as full-size RGBA output, excluding codec working storage.

## Method and limits

Each compressed JPEG is read into memory before timing, modelling an already-extracted archive entry. An initial downsample creates the reference buffer. Five further original decodes each construct a fresh ImageSource, measuring metadata initialization and decode-to-2K, without archive extraction or input loading.

The exact reference buffer is encoded as PNG and JPEG at quality 0.95. One warm-up per format is excluded. Seven measured iterations alternate format order; each writes a unique filename. Write timing includes encoding, file writing and atomic rename. Reload timing includes opening that file, constructing a fresh ImageSource and decoding it fully into a PixelBuffer. It does not reuse an ImageSource's decoded-image cache.

The recently written files are likely resident in the OS filesystem cache. These are **warm-filesystem reloads**, not cold-storage measurements. Timings exclude archive extraction, GPU upload and UI rendering. Writes are not explicitly fsynced, so they measure normal API completion rather than guaranteed power-loss durability. The main table uses arithmetic means from the first successful run. A second launch also completed; its raw measurements are retained separately, not pooled. Thermal state was nominal throughout both runs.

Process physical footprint is sampled every 5 ms on a separate queue and at operation completion. It includes the host, loaded compressed input, reference pixels and measured allocations. Peak values below cover the five measured original decodes; the initial reference decode was a warm-up outside sampling. Sampling can miss short spikes and these are not guaranteed memory ceilings.

## Results

Sizes use decimal MB (1,000,000 bytes). Times are milliseconds **per page**, one operation at a time.

| Page | Original → 2K decode | PNG MB | PNG write | PNG reload | JPEG .95 MB | JPEG write | JPEG reload |
|---|---:|---:|---:|---:|---:|---:|---:|
| 001 | 188.0 | 4.61 | 205.1 | 83.5 | 0.89 | 36.9 | 34.6 |
| 015 | 343.1 | 2.68 | 113.3 | 56.5 | 1.52 | 43.7 | 32.6 |
| 151 | 331.7 | 2.78 | 116.4 | 58.4 | 1.60 | 45.8 | 33.0 |
| 170 | 228.0 | 1.32 | 77.6 | 48.3 | 0.83 | 32.6 | 27.8 |
| 281 | 193.4 | 0.79 | 60.6 | 36.6 | 0.59 | 25.2 | 25.4 |
| Mean of selected pages | 256.8 | 2.44 | 114.6 | 56.7 | 1.09 | 36.8 | 30.7 |

Page 15's JPEG cache is approximately 15 times smaller than its original file and reloads about 10.5 times faster than decoding the original to the same size in these measurements. PNG reload is about 6.1 times faster. The initial cache miss still pays the original downsample cost plus encoding; the gains apply to subsequent visits.

| Page | Peak process MiB during measured original downsample | Largest extra peak over operation baseline MiB |
|---|---:|---:|
| 001 | 85.6 | 58.0 |
| 015 | 70.5 | 24.0 |
| 151 | 69.4 | 24.1 |
| 170 | 57.1 | 24.1 |
| 281 | 54.8 | 24.1 |

These observations are consistent with the JPEG thumbnail path avoiding a retained full-resolution RGBA output. They are specific to these JPEGs and do not establish the same behavior for every codec or input.

## Fidelity

PNG reloads matched the downsampled reference **exactly in every RGB channel** on all five opaque pages. This means no additional compression loss; it does not restore detail removed by downsampling.

| Page | JPEG mean absolute RGB error / 255 | Maximum channel error / 255 | PSNR dB |
|---|---:|---:|---:|
| 001 | 1.919 | 49 | 38.29 |
| 015 | 0.718 | 8 | 46.70 |
| 151 | 0.701 | 8 | 46.78 |
| 170 | 0.342 | 7 | 50.11 |
| 281 | 0.209 | 7 | 52.27 |

Exported page-15 lettering/line-art and colour-cover crops were inspected at 200% nearest-neighbour magnification. JPEG retained readable, closely matching lettering, with small changes around edges and colour detail. Numerical similarity is not a guarantee for every page, and JPEG is still lossy. PNG is appropriate when exact downsampled pixels matter; JPEG at 0.95 is a useful size/speed tradeoff for this archive. Preserve the originals for deeper zoom, and include the target resolution and processing version in cache keys.

## JPEG quality and file-size follow-up

The user's concern about re-encoding JPEG artifacts prompted a second probe at quality 0.85, 0.90 and 0.95. All settings encode the same 1365×2048 reference pixels. Each setting receives one excluded warm-up and five measured iterations, alternating ascending/descending quality order. The probe passed and thermal state remained nominal. These normalized values are ImageIO settings, not assumed equivalent to another JPEG encoder's quality scale.

| Page | JPEG .85 MB | JPEG .90 MB | JPEG .95 MB | Saving at .85 versus .95 |
|---|---:|---:|---:|---:|
| 001 | 0.774 | 0.825 | 0.888 | 12.8% |
| 015 | 1.397 | 1.434 | 1.516 | 7.9% |
| 151 | 1.480 | 1.518 | 1.604 | 7.7% |
| 170 | 0.770 | 0.788 | 0.832 | 7.5% |
| 281 | 0.551 | 0.563 | 0.592 | 6.9% |

For page 15, .85/.90/.95 mean write times were 40.1/40.6/42.1 ms; warm-filesystem reloads were 29.9/29.1/32.0 ms. Mean absolute RGB errors were 0.950/0.828/0.718 out of 255, with PSNR 44.38/45.55/46.70 dB. The .85 lettering and colour-cover crops were visually compared with the prior .95/PNG crops at 200%; differences were small, without an obvious loss of lettering readability.

There was no dramatic .95 file-size increase relative to .85 on these pages. Keeping .95 is reasonable when fidelity matters; .85 saves 7–13% of cache bytes across the sample. Every cache file remained smaller than its original here. This does not prove that downsizing any JPEG will always reduce file size, or identify how much of each original's detail is compression artifact. Always generate a cache from the original, not another lossy cache generation.

Source and raw fields for `testJPEGQualitySweep` are included with the main probe. Evidence: `/tmp/ImageIOKit-cache-probe/quality-sweep.log` and `.xcresult`; exported comparison images are in `/tmp/ImageIOKit-cache-quality-images`.

## Verification and reproduction

- All 153 Swift 6 Release package tests passed on iOS 18.5 simulator.
- All 22 ImageDestinationTests passed on the physical iPad, including five new buffer-writer regressions. The normal example app was restored afterward.
- New tests cover padded rows, PNG pixel/alpha round trips, JPEG RGB and grayscale alpha compositing, all buffer layouts, Display P3, replacement and failure cleanup. Independent review found no blocking issues.
- [Raw results](2026-09-26-disk-cache-results.json) contain each iteration's timing and sampled memory, plus both completed runs.
- [Standalone probe source](2026-09-26-cache-probe.swift) is excluded from production/test targets. Copy it into a temporary example test project and add the five listed JPEGs as a `ProbeFixtures` folder resource, using neutral filenames `page001.jpg`, `page015.jpg`, `page151.jpg`, `page170.jpg` and `page281.jpg`. Disable the example controller's delayed decode while benchmarking.
- Primary evidence: `/tmp/ImageIOKit-cache-probe/cache-final.log` and `.xcresult`. Additional run: `cache-run.log` and `.xcresult` in that directory.
- PNG/JPEG attachments were exported to `/tmp/ImageIOKit-cache-images` for local visual inspection.
- Test logs: `/tmp/ImageIOKit-cache-package-final.log` and `/tmp/ImageIOKit-cache-device-final.log`.

The benchmark was run with `xcodebuild test`, scheme `ImageIOKitTests`, Release, physical iPad destination, `-parallel-testing-enabled NO`, `-enableCodeCoverage NO`, `ENABLE_TESTABILITY=YES`, selecting `MemoryTrackingTests/testDiskCacheBenchmark`. App cache policy and concurrent encoding were not part of this probe.
