# Benchmark harness

This harness produced the 2026-11-06 benchmark write-ups. It has two parts:

- A **macOS harness**: a SwiftPM package that builds a copy of the library natively for macOS with testability, plus probes.
- An **iPhone harness**: a temporary copy of the example app whose `ViewController` runs a benchmark mode on launch and prints results to the console.

The iPhone harness runs inside the app rather than as an XCTest. One reason is that the example test target can't bundle large fixtures. The other is that `xcodebuild test` launches failed in the environment where these benchmarks were made. App launches with `devicectl --console` work everywhere.

Both scripts copy the current repo sources into `/tmp`, so the working tree is never modified.

## macOS

```sh
bash docs/benchmarks/harness/setup-mac.sh            # builds /tmp/ImageIOKit-gpu-bench
B=/tmp/ImageIOKit-gpu-bench
$B/.build/release/GPUScaleBench $B/fixtures [png-output-dir]   # first run generates the fixtures (~75 MB)
$B/.build/release/RealPages /path/to/pages/*.jpg     # real pages: metadata, decode vs makeTexture at three screen sizes
$B/.build/release/GrayCheck /path/to/gray/*.jpg      # TurboJPEG gray decode vs conversion vs ImageIO, stage by stage
$B/.build/release/BoxCheck /path/to/*.jxl            # JXL 2x box filter vs full decode; native color space tagging
$B/.build/release/ICCCheck                           # how tj3GetICCProfile reports missing, valid and corrupt profiles
```

`GPUScaleBench` is [2026-11-06-gpu-scale-probe.swift](../2026-11-06-gpu-scale-probe.swift). It compares the shipped pipeline with native-scale decodes resampled by CoreGraphics or MPS, against an exact area-average ground truth.

## iPhone

```sh
bash docs/benchmarks/harness/setup-ios.sh /tmp/ImageIOKit-gpu-bench/fixtures [/path/to/real/pages]
P=/tmp/ImageIOKit-device-project
DEVICE=<udid from `xcrun devicectl list devices`>
xcodebuild build -project $P/ImageIOKit.xcodeproj -scheme ImageIOKitExample -configuration Release \
  -destination "platform=iOS,id=$DEVICE" -derivedDataPath $P/DerivedData -allowProvisioningUpdates
xcrun devicectl device install app --device $DEVICE $P/DerivedData/Build/Products/Release-iphoneos/ImageIOKitExample.app
xcrun devicectl device process launch --device $DEVICE --console --terminate-existing dev.tim.ImageIOKit <mode>
```

Keep the device unlocked, with Auto-Lock off, during builds and runs. The app installs over ImageIOKitExample (`dev.tim.ImageIOKit`) and exits when it is done.

| Launch arguments | What it runs |
|---|---|
| (none), `--only=<substring>` | The full GPU-scale benchmark, optionally limited to fixtures whose name contains the substring |
| `--real` | Bundled real pages (from `setup-ios.sh`'s second argument) at iPhone SE, Pro Max and iPad sizes |
| `--memory [--label=name]` | Peak footprint and median time of `makeTexture`, sampled every 1 ms. It alternates calls in pairs; the copy-upload vs shared-storage A/B needs the temporary `ImageSource.benchmarkCopyUpload` switch described in the 2026-11-06 write-up, which is not in the library |
| `--diag` | ImageIO subsampled-JPEG bitmap layout, alignment, and per-stage timings |
| `--experiments` | Swizzle check, direct ImageIO upload, Core Image Lanczos |
| `--vt` | VideoToolbox Motion-JPEG hardware decode probe |

`setup-ios.sh` patches its library copy to let untagged gray JPEGs through TurboJPEG as sRGB, so the TurboJPEG RGBA pipelines can be timed on the gray fixture. This is timing-only; the library itself keeps those pages on ImageIO.

The real CBZ pages used on 2026-11-06 came from a public sample reading-media set and are not committed. Extract the JPEGs from any CBZ into a folder and pass that folder.
