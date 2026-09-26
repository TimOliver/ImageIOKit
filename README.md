# ImageIOKit

<a href="https://github.com/TimOliver/ImageIOKit/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
<a href="https://swiftpackageindex.com/TimOliver/ImageIOKit"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTimOliver%2FImageIOKit%2Fbadge%3Ftype%3Dplatforms" alt="Platforms"></a>
<a href="https://swiftpackageindex.com/TimOliver/ImageIOKit"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTimOliver%2FImageIOKit%2Fbadge%3Ftype%3Dswift-versions" alt="Swift Versions"></a>

A Swift image decoding and encoding library built on Apple's [ImageIO](https://developer.apple.com/documentation/imageio) framework. Designed as a building block for apps that display images across multiple formats, with an emphasis on low memory overhead and efficient format conversion.

ImageIOKit supports **JPEG**, **PNG**, **WebP**, **HEIC**, **AVIF**, and **JPEG XL**, and provides native sub-region decoding for JPEG via [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo), and lossless JPEG reconstruction from JPEG XL via [libjxl](https://github.com/libjxl/libjxl).

## Features

- **Multi-format decoding** — Full-resolution, thumbnailed, and cropped decodes from a single `ImageSource` API.
- **JPEG region decode** — Decode arbitrary sub-regions of JPEG files without loading the entire image into memory (via TurboJPEG cropped decode).
- **Native WebP scaling** — Decode still WebP images directly into smaller pixel buffers via libwebp, with premultiplied alpha and ICC color management.
- **JPEG XL reconstruction** — Losslessly reconstruct the original JPEG bitstream from JXL-from-JPEG files, with zero quality loss and no decode overhead.
- **ImageIO encoding** — Encode and transcode via `CGImageDestinationAddImageFromSource`. ImageIO manages conversion; cross-format encoding can require decoding and re-encoding.
- **Image conditioning** — Convert any supported format to JPEG on disk in a single call, giving every image shrink-on-load thumbnailing and region decode for free.
- **Raw pixel access** — Decode into `PixelBuffer` (C-allocated, zero-copy `CGImage` via retained `CGDataProvider`) in 4 pixel formats: RGBA, RGB, Grayscale, and Grayscale+Alpha.
- **Metal texture support** — Create `MTLTexture` directly from a `PixelBuffer`.
- **Memory budgeting** — Operation-specific estimates include output pixels, rendering intermediates, and codec working storage to help schedule concurrent decodes.
- **Consistent pixels** — Decodes apply EXIF orientation; raw RGB buffers use sRGB and premultiplied alpha. JPEG region decoding respects embedded ICC profiles.
- **Purgeable caching** — Full-resolution `CGImage` results are cached via `NSCache` and automatically evicted under memory pressure.

## Requirements

- iOS 16.0+ (the minimum supported by the bundled libjpeg-turbo and libjxl dependencies)
- Swift 6.0+
- Xcode 16.0+

Individual formats also depend on the operating system's ImageIO support. In particular,
the public `ImageSource` facade still uses ImageIO to read JPEG XL metadata; linking
libjxl does not by itself enable JPEG XL on older operating systems. Check
`ImageFileFormat.isSupportedByOSVersion` before offering a format.

## Installation

### Swift Package Manager

Add ImageIOKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/TimOliver/ImageIOKit.git", from: "1.0.0")
]
```

Or add it via Xcode: **File > Add Package Dependencies** and enter the repository URL.

### Xcode Project

ImageIOKit can also be used as a source folder added directly to an Xcode project. The primary development environment is an Xcode project (`ImageIOKit.xcodeproj`) with an example app target.

## Usage

### Creating an Image Source

```swift
import ImageIOKit

// From a file URL
guard let source = ImageSource(url: imageURL) else { throw ImageDecoderError.invalidData }

// From in-memory data
let memorySource = ImageSource(data: imageData)

// Deferred loading (call loadImageData explicitly before decoding)
let deferredSource = ImageSource(url: imageURL, loadImmediately: false)
deferredSource?.loadImageData()
```

### Reading Image Metadata

```swift
source.imageSize      // CGSize — upright display-pixel dimensions
source.fileFormat     // ImageFileFormat — .jpeg, .png, .webp, .heic, .avif, .jpegXL
source.hasAlpha       // Bool
source.colorModel     // ImageColorModel — .rgb, .grayscale, .cmyk, .lab
source.colorProfile   // String — ICC profile name
```

### Decoding

```swift
// Full-resolution UIImage
let image = source.decodeFullImage()

// Thumbnail (ImageIO shrink-on-load, avoids full decode when possible)
let thumb = source.makeThumbnail(fittingSize: CGSize(width: 200, height: 200))

// Raw pixel buffer with target size and crop
let buffer = try source.decode(
    targetSize: CGSize(width: 1024, height: 1024),
    cropRect: CGRect(x: 100, y: 100, width: 500, height: 500),
    pixelFormat: .rgba8
)

// JPEG sub-region decode (no full-image decode)
let region = source.decodeRegion(CGRect(x: 0, y: 0, width: 256, height: 256))
```

All decoded images are upright. Crop rectangles use upright pixel coordinates with a top-left origin and are rounded outward and clamped to `imageSize`. Target sizes are bounding boxes: both dimensions are respected, aspect ratio is preserved (subject to pixel rounding), and small images are not upscaled. Rotated or mirrored JPEG regions currently use the full-decode fallback; `isRegionDecodable` reports whether native region decode is available.

WebP thumbnails and raw pixel buffers use libwebp for upright still images. Supported crops are applied before native scaling. Animation, rotated/mirrored images, unsupported ICC profiles, and lossy crops with odd x/y origins retain ImageIO fallbacks. Full-image `CGImage`/`UIImage` decoding continues to use ImageIO. WebP cropping is not random-access tile decoding: lossless and alpha images can still require source-sized working storage, so `isRegionDecodable` remains false for WebP and memory estimates retain their full-resolution allowance.

JPEG XL thumbnails use the approximately 1/8-resolution DC preview when it is large enough. Larger thumbnails average 2×2 or 4×4 pixel blocks in libjxl's output callbacks before the final resize, avoiding a full-resolution output bitmap when at least 2× reduction is possible. This filtering preserves orientation, color profiles, and premultiplied alpha; it is not pixel-identical to resizing a full decode. The codec still processes full image detail above the DC limit and can require source-sized working storage. See the [iPad JXL measurements](docs/benchmarks/2026-09-26-jxl-improvements.md).

### Encoding and Transcoding

To cache a downsampled page, encode the decoded buffer directly. This reuses its pixels, including the optimized JXL/WebP thumbnail paths:

```swift
let pixels = try source.decode(targetSize: CGSize(width: 2048, height: 2048))
// Display pixels.makeCGImage(), and write from your decoding/cache queue.
try pixels.write(to: cacheURL, as: .png) // Lossless compression; retains alpha.
// Or use JPEG for a smaller lossy cache:
try pixels.write(to: jpegCacheURL, as: .jpeg) // Defaults to quality 0.95.
```

`PixelBuffer.write` is synchronous and retains the buffer's color profile. JPEG composites transparency over black. It writes a sibling temporary file and atomically replaces the destination after successful encoding; the parent directory must already exist. Do not mutate the pixels while writing. Encoder availability depends on ImageIO on the device. Keep the archive originals for zooming beyond the cached resolution.

See the [iPad disk-cache benchmark](docs/benchmarks/2026-09-26-disk-cache.md) for PNG versus JPEG quality, size, write time, reload time, and source-downsampling memory on oversized publisher comic pages. The [real JXL comic benchmark](docs/benchmarks/2026-09-27-real-jxl.md) covers per-page decode latency, concurrency and caching at typical comic dimensions.

```swift
// Encode to a format using ImageIO
let jpegData = try source.encoded(as: .jpeg, quality: 0.85)

// Write directly to disk
try source.write(to: outputURL, as: .png)

// Transcode between formats (JXL → JPEG uses lossless reconstruction when available)
let data = try source.transcoded(to: .jpeg)
```

### Conditioning

Conditioning converts any image to JPEG on disk, optionally downscaling oversized images. The resulting JPEG is optimized for efficient partial decoding and thumbnailing.

```swift
let conditioned = try source.writeConditionedJPEG(maxDimension: 4096, to: outputURL, quality: 0.85)
// conditioned is a new ImageSource pointing at the JPEG file
// Existing small-enough JPEGs are copied byte-for-byte; quality is ignored for copies.
// The destination is always written on success, including when it already exists.
```

### Pixel Buffers

```swift
let buffer = try source.decode(pixelFormat: .rgba8)

buffer.width         // Int
buffer.height        // Int
buffer.bytesPerRow   // Int
buffer.data          // UnsafeMutableRawPointer
buffer.colorSpace    // CGColorSpace describing the components

// Zero-copy CGImage (backed by the buffer's memory)
let cgImage = buffer.makeCGImage()

// Metal texture
let texture = buffer.makeTexture(device: mtlDevice)
```

### Memory Budgeting

```swift
// Estimate peak memory for a full decode
let bytes = source.estimatedDecodeMemory

// Estimate a particular raw decode, including format conversion
let thumbnailBytes = try source.estimatedDecodeMemory(
    targetSize: CGSize(width: 200, height: 300),
    pixelFormat: .grayAlpha8
)

// Compare against available memory before decoding
if bytes < os_proc_available_memory() {
    let image = source.decodeFullImage()
}
```

Memory estimates are planning heuristics, not hard limits. They include a full-resolution codec allowance because thumbnails and regions can fall back to full decoding. Compressed input and previously cached images are excluded; allow additional headroom when scheduling work.

## Architecture

ImageIOKit is structured around a single public facade (`ImageSource`) that wraps Apple's `CGImageSource` and `CGImageDestination`:

```
ImageSource (facade)
├── Decoding (ImageSource+Decoding)
│   ├── Thumbnails via CGImageSourceCreateThumbnailAtIndex
│   ├── Full decode via CGImageSourceCreateImageAtIndex
│   ├── JPEG region decode via JPEGRegionDecoder (TurboJPEG cropping)
│   ├── WebP thumbnails and raw buffers via WebPImageDecoder (native scaling/cropping)
│   └── JXL thumbnail via JXLDecoder (DC preview or filtered output callbacks)
├── Encoding (ImageSource+Encoding)
│   ├── ImageIO encode via CGImageDestinationAddImageFromSource
│   ├── Alpha-strip fallback via CGImage.strippingAlpha()
│   ├── Conditioning (any format → JPEG on disk)
│   ├── Transcoding (format → format)
│   └── JXL → JPEG lossless reconstruction via JXLReconstructor
└── PixelBuffer
    ├── C-allocated pixel data (rgba8, rgb8, gray8, grayAlpha8)
    ├── Zero-copy CGImage via CGDataProvider
    └── Metal texture creation
```

### C Library Carve-outs

While ImageIO handles most decode/encode operations, three C libraries provide additional codec controls:

| Library | Purpose | Import |
|---------|---------|--------|
| [libjpeg-turbo](https://github.com/TimOliver/libjpeg-turbo-cocoa) | JPEG sub-region decode (`tj3SetCroppingRegion`) | `import turbojpeg` |
| [libjxl](https://github.com/TimOliver/libjxl-cocoa) | JXL → JPEG lossless reconstruction, DC and filtered thumbnail decode | `import jxl` |
| [libwebp](https://github.com/TimOliver/WebP-Cocoa) | Still-image scaling/cropping, premultiplied output, ICC extraction; decoder-only `WebPDecoding` product | `import WebPDecoder`, `import WebPDemux` |

## Testing

Run `bash scripts/test-package.sh` to build and test the actual Swift 6 package in Release mode using an installed iPhone simulator. An explicit Xcode destination can be supplied as the first argument. The same tests also run through the `ImageIOKitTests` Xcode scheme.

Tests include small generated fixtures for all EXIF orientations, rectangular bounds, wide-gamut JPEG regions, associated and unassociated JXL alpha, format signatures, and conditioned-file writes, alongside the existing photo and memory tests. CI runs the package suite independently of the example app.

WebP fixtures cover lossy/lossless pixels, transparency, animation fallbacks, ICC profiles, and exact crop coordinates. Regenerate the synthetic files with `bash scripts/generate-webp-fixtures.sh` using libwebp 1.6.0 command-line tools; test executables do not link the encoder.

## Credits

ImageIOKit was created by [Tim Oliver](https://twitter.com/TimOliverAU).

## License

ImageIOKit is available under the MIT license. See [LICENSE](LICENSE) for details.
