# ImageIOKit

## Target
- iOS 18+
- Swift, Xcode project (not SPM primary)

## Purpose
Image decode library for a comic reader app.

## Usage Constraints
- Displays 2 pages side-by-side
- 2 screens worth of pages preheated ahead
- User manages caching and scheduling externally; library provides building blocks only
- Pages may arrive in any format (JPEG, PNG, WebP, AVIF, JXL) and may be oversized

## Architecture
- All decode/thumbnail/encode via Apple ImageIO (`CGImageSource` / `CGImageDestination`)
- Two C library carve-outs:
  - **libjpeg** — JPEG region decode (`crop_scanline`) for tile-based zoom
  - **libjxl** — lossless JPEG reconstruction from JXL (`JXL_DEC_JPEG_RECONSTRUCTION`)
- Encoding uses `CGImageDestinationAddImageFromSource` for zero-decode stream copies when no alpha strip is needed
- `ImageSource.condition` transcodes non-JPEG sources to JPEG on disk, giving them shrink-on-load and region decode for free

## Key Classes
- `ImageSource` — public facade wrapping `CGImageSource`. `decode(targetSize:cropRect:pixelFormat:)` for full/thumbnail/cropped decode into `PixelBuffer`. `isRegionDecodable` indicates JPEG sources that support native sub-region decode. Caches full-resolution `CGImage` via `NSCache` (purgeable under memory pressure). `estimatedDecodeMemory` for memory budgeting. Supports Xcode Quick Look via `debugQuickLookObject()`.
- `ImageSource+Encoding` — `encode(as:quality:)` and `write(to:as:quality:)` via `CGImageDestination` with zero-decode fast path. `writeConditionedJPEG(maxDimension:to:quality:)` and `transcoded(to:quality:)` for conditioning/transcoding workflows. `reconstructJPEGfromJPEGXL()` for lossless JXL → JPEG bitstream reconstruction.
- `JPEGRegionDecoder` — libjpeg `crop_scanline` for JPEG-only tile decode (`import turbojpeg`)
- `JXLDecoder` — libjxl scanline-callback decode into `PixelBuffer`. DC-only thumbnail path via `JXL_DEC_FRAME_PROGRESSION` for ~1/8th resolution at ~2% memory cost (`import jxl`)
- `JXLReconstructor` — libjxl JPEG bitstream reconstruction for JXL-from-JPEG sources (`import jxl`)
- `PixelBuffer` — C-allocated pixel data with zero-copy `CGImage` via retained `CGDataProvider`. Supports 4 formats: `rgba8`, `rgb8`, `gray8`, `grayAlpha8`. Metal texture creation via `makeTexture(device:)`.
- `SoftwareScaler` — crop and aspect-ratio fitting utility for `PixelBuffer`.

## CGContext Constraints
- CGContext at 8bpc only supports **gray/no-alpha (1 byte)** and **RGB+alpha or RGB+skip (4 bytes)**
- 3-byte RGB and 2-byte gray+alpha are **not** valid CGContext configurations — render to a supported intermediate (RGBX or RGBA) and convert
- Use integer arithmetic for BT.601 luminance (`299*R + 587*G + 114*B`) to avoid floating-point boundary errors

## SPM Dependencies
- `libjpeg-turbo` (TimOliver/libjpeg-turbo-cocoa ≥ 3.1.3) — precompiled libjpeg-turbo xcframework; `import turbojpeg`, product `turbojpeg`
- `libjxl` (TimOliver/libjxl-cocoa ≥ 0.11.2) — precompiled libjxl xcframework; `import jxl`, product `jxl`
