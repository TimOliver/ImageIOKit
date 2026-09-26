# ImageIOKit

## Target
- iOS 18+, Swift 6 package; an Xcode example app also compiles the sources.
- Image decoding and conversion building blocks for a comic reader.
- Callers manage scheduling and page caching externally.

## Architecture
- `ImageSource` wraps ImageIO for metadata, full decode, thumbnails, and encoding.
- `JPEGRegionDecoder` uses TurboJPEG cropped decode and DCT scaling. It retains embedded RGB ICC profiles; ImageIO handles unsupported profiles and rotated/mirrored source regions.
- `JXLDecoder` uses libjxl callbacks for full and DC-resolution decoding, retains output color profiles, and normalizes alpha to premultiplied components.
- `JXLReconstructor` reconstructs the original JPEG bitstream from JPEG-derived JXL.
- `WebPImageDecoder` uses libwebp's decoder-only product for scaled still-image pixels, retaining RGB ICC profiles and emitting premultiplied RGBA directly into `PixelBuffer`. ImageIO handles animation, transformed images, unsupported profiles, and odd-origin lossy crops.
- `PixelBuffer` owns pixel storage and its color space. `makeCGImage()` retains the buffer without copying; `makeTexture(device:)` copies its components to Metal.
- `SoftwareScaler` centralizes aspect fitting and crop validation.


## Key Classes
- `ImageSource` — public facade wrapping `CGImageSource`. `decode(targetSize:cropRect:pixelFormat:)` for full/thumbnail/cropped decode into `PixelBuffer`. `isRegionDecodable` indicates JPEG sources that support native sub-region decode. Caches full-resolution `CGImage` via `NSCache` (purgeable under memory pressure). `estimatedDecodeMemory` for memory budgeting. Supports Xcode Quick Look via `debugQuickLookObject()`.
- `ImageSource+Encoding` — `encode(as:quality:)` and `write(to:as:quality:)` via `CGImageDestination` with zero-decode fast path. `writeConditionedJPEG(maxDimension:to:quality:)` and `transcoded(to:quality:)` for conditioning/transcoding workflows. `reconstructJPEGfromJPEGXL()` for lossless JXL → JPEG bitstream reconstruction.
- `JPEGRegionDecoder` — libjpeg `crop_scanline` for JPEG-only tile decode (`import turbojpeg`)
- `JXLDecoder` — libjxl scanline-callback decode into `PixelBuffer`. DC-only thumbnail path via `JXL_DEC_FRAME_PROGRESSION` for ~1/8th resolution at ~2% memory cost (`import jxl`)
- `JXLReconstructor` — libjxl JPEG bitstream reconstruction for JXL-from-JPEG sources (`import jxl`)
- `PixelBuffer` — C-allocated pixel data with zero-copy `CGImage` via retained `CGDataProvider`. Supports 4 formats: `rgba8`, `rgb8`, `gray8`, `grayAlpha8`. Metal texture creation via `makeTexture(device:)`.
- `SoftwareScaler` — crop and aspect-ratio fitting utility for `PixelBuffer`.

## Public Contracts
- `imageSize` and crop coordinates describe upright, display-oriented pixels. Crop origin is top-left; fractional crops round outward and clamp to image bounds.
- All decode outputs apply EXIF orientation. Target sizes fit both dimensions and never upscale.
- `decode(targetSize:cropRect:pixelFormat:)` returns sRGB components for RGB formats. Alpha-bearing formats are premultiplied. Opaque output composites transparency over black.
- `encoded(as:quality:)` and `write(to:as:quality:)` use ImageIO conversion. `CGImageDestinationAddImageFromSource` does not guarantee compressed-byte copies or zero decode.
- `transcoded(to:quality:)` attempts lossless JXL-to-JPEG reconstruction first.
- `writeConditionedJPEG(maxDimension:to:quality:)` always writes the destination. Existing JPEGs within the size limit are copied byte-for-byte and ignore quality; the returned source points to the destination.
- `estimatedDecodeMemory` covers default full RGBA decode. Its method overload accounts for target size, crop, and pixel format. Both are planning heuristics, include full-resolution codec allowances, and exclude existing caches and compressed input.

## C Interop
- libjxl input pointers must remain valid until the decoder releases input or is destroyed. Keep processing and destruction within `Data.withUnsafeBytes`.
- Callback context uses stable allocated storage, destroyed after the decoder and before the thread runner.
- TurboJPEG ICC buffers must be released using `tj3Free`.
- WebP demux chunk pointers borrow compressed input; extraction and decoding stay inside `Data.withUnsafeBytes`. Output storage is caller-owned. Lossless/alpha working memory can still scale with source dimensions.


## SPM Dependencies
- `libjpeg-turbo` (TimOliver/libjpeg-turbo-cocoa ≥ 3.1.3) — precompiled libjpeg-turbo xcframework; `import turbojpeg`, product `turbojpeg`
- `libjxl` (TimOliver/libjxl-cocoa ≥ 0.11.2) — precompiled libjxl xcframework; `import jxl`, product `jxl`

## Rendering
- CGContext supports 8-bit gray and four-component RGB layouts. Render RGB and gray-alpha through a zero-filled RGBA intermediate, then convert.
- Scale and color-convert directly into the final output allocation where supported.

## Testing
- `bash scripts/test-package.sh` tests the actual package in Swift 6 Release mode on an available iPhone simulator. Pass an Xcode destination as the first argument to select a device.
- The script isolates the package scheme from the example project using temporary source symlinks; source files remain in the working tree.
- The Xcode `ImageIOKitTests` scheme runs the same tests against the example target.
- Regression fixtures cover EXIF orientations, rectangular bounds, ICC profiles, JXL alpha, sliced data, container brands, and conditioned writes.
- libjxl synthetic fixture encoding requires the C++ runtime in test targets.

