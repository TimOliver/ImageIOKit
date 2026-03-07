# ImageIOKit

<a href="https://github.com/TimOliver/ImageIOKit/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
<a href="https://swiftpackageindex.com/TimOliver/ImageIOKit"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTimOliver%2FImageIOKit%2Fbadge%3Ftype%3Dplatforms" alt="Platforms"></a>
<a href="https://swiftpackageindex.com/TimOliver/ImageIOKit"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTimOliver%2FImageIOKit%2Fbadge%3Ftype%3Dswift-versions" alt="Swift Versions"></a>

A Swift image decoding and encoding library built on Apple's [ImageIO](https://developer.apple.com/documentation/imageio) framework. Designed as a building block for apps that display images across multiple formats, with an emphasis on low memory overhead and efficient format conversion.

ImageIOKit supports **JPEG**, **PNG**, **WebP**, **HEIC**, **AVIF**, and **JPEG XL**, and provides native sub-region decoding for JPEG via [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo), and lossless JPEG reconstruction from JPEG XL via [libjxl](https://github.com/libjxl/libjxl).

## Features

- **Multi-format decoding** — Full-resolution, thumbnailed, and cropped decodes from a single `ImageSource` API.
- **JPEG region decode** — Decode arbitrary sub-regions of JPEG files without loading the entire image into memory (via TurboJPEG cropped decode).
- **JPEG XL reconstruction** — Losslessly reconstruct the original JPEG bitstream from JXL-from-JPEG files, with zero quality loss and no decode overhead.
- **Zero-decode encoding** — Encode and transcode via `CGImageDestinationAddImageFromSource`, copying compressed data directly from source to destination when no pixel-level transformation (e.g. alpha stripping) is needed.
- **Image conditioning** — Convert any supported format to JPEG on disk in a single call, giving every image shrink-on-load thumbnailing and region decode for free.
- **Raw pixel access** — Decode into `PixelBuffer` (C-allocated, zero-copy `CGImage` via retained `CGDataProvider`) in 4 pixel formats: RGBA, RGB, Grayscale, and Grayscale+Alpha.
- **Metal texture support** — Create `MTLTexture` directly from a `PixelBuffer`.
- **Memory budgeting** — `estimatedDecodeMemory` provides per-format estimates of peak memory usage to help schedule concurrent decodes.
- **Purgeable caching** — Full-resolution `CGImage` results are cached via `NSCache` and automatically evicted under memory pressure.

## Requirements

- iOS 18.0+
- Swift 6.0+
- Xcode 16.0+

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
let source = ImageSource(url: imageURL)

// From in-memory data
let source = ImageSource(data: imageData)

// Deferred loading (header read on first use)
let source = ImageSource(url: imageURL, loadImmediately: false)
source.loadImageData()
```

### Reading Image Metadata

```swift
source.imageSize      // CGSize — pixel dimensions
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

### Encoding and Transcoding

```swift
// Encode to a format (zero-decode fast path when possible)
let jpegData = try source.encode(as: .jpeg, quality: 0.85)

// Write directly to disk
try source.write(to: outputURL, as: .png)

// Transcode between formats (JXL → JPEG uses lossless reconstruction when available)
let data = try source.transcode(to: .jpeg)
```

### Conditioning

Conditioning converts any image to JPEG on disk, optionally downscaling oversized images. The resulting JPEG is optimized for efficient partial decoding and thumbnailing.

```swift
let conditioned = try source.writeConditionedJPEG(maxDimension: 4096, to: outputURL, quality: 0.85)
// conditioned is a new ImageSource pointing at the JPEG file
// If the source was already a small-enough JPEG, returns `self` (no work done)
```

### Pixel Buffers

```swift
let buffer = try source.decode(pixelFormat: .rgba8)

buffer.width         // Int
buffer.height        // Int
buffer.bytesPerRow   // Int
buffer.data          // UnsafeMutableRawPointer

// Zero-copy CGImage (backed by the buffer's memory)
let cgImage = buffer.makeCGImage()

// Metal texture
let texture = buffer.makeTexture(device: mtlDevice)
```

### Memory Budgeting

```swift
// Estimate peak memory for a full decode
let bytes = source.estimatedDecodeMemory

// Compare against available memory before decoding
if bytes < os_proc_available_memory() {
    let image = source.decodeFullImage()
}
```

## Architecture

ImageIOKit is structured around a single public facade (`ImageSource`) that wraps Apple's `CGImageSource` and `CGImageDestination`:

```
ImageSource (facade)
├── Decoding (ImageSource+Decoding)
│   ├── Thumbnails via CGImageSourceCreateThumbnailAtIndex
│   ├── Full decode via CGImageSourceCreateImageAtIndex
│   ├── JPEG region decode via JPEGRegionDecoder (TurboJPEG cropping)
│   └── JXL thumbnail via JXLDecoder (libjxl DC-only progressive decode)
├── Encoding (ImageSource+Encoding)
│   ├── Zero-decode encode via CGImageDestinationAddImageFromSource
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

While ImageIO handles the vast majority of decode/encode operations, two C libraries are used for capabilities ImageIO does not provide:

| Library | Purpose | Import |
|---------|---------|--------|
| [libjpeg-turbo](https://github.com/TimOliver/libjpeg-turbo-cocoa) | JPEG sub-region decode (`tj3SetCroppingRegion`) | `import turbojpeg` |
| [libjxl](https://github.com/TimOliver/libjxl-cocoa) | JXL → JPEG lossless reconstruction, DC-only thumbnail decode | `import jxl` |

## Credits

ImageIOKit was created by [Tim Oliver](https://twitter.com/TimOliverAU).

## License

ImageIOKit is available under the MIT license. See [LICENSE](LICENSE) for details.
