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
- `ImageSource.condition` transcodes non-JPEG sources to JPEG on disk, giving them shrink-on-load and region decode for free

## Key Classes
- `ImageSource` — public facade wrapping `CGImageSource`. Decode, thumbnail, region decode, JPEG reconstruction. Caches full-resolution `CGImage` via `NSCache` (purgeable under memory pressure). Supports Xcode Quick Look via `debugQuickLookObject()`. Extended with `condition(maxDimension:to:)` and `transcode(to:)` for conditioning/transcoding workflows.
- `CGImage` extensions — `encode(as:options:)` and `write(to:as:options:)` via `CGImageDestination`.
- `JPEGRegionDecoder` — libjpeg `crop_scanline` for JPEG-only tile decode
- `JXLReconstructor` — libjxl JPEG bitstream reconstruction for JXL-from-JPEG sources
- `TileManager` — on-demand tile decode with `NSCache`. JPEG tiles via parallel region decode; all other formats via `CGImage.cropping(to:)` on the cached full decode.
- `PixelBuffer` — C-allocated pixel data with zero-copy `CGImage` via retained `CGDataProvider`. Supports 4 formats: `rgba8`, `rgb8`, `gray8`, `grayAlpha8`.

## CGContext Constraints
- CGContext at 8bpc only supports **gray/no-alpha (1 byte)** and **RGB+alpha or RGB+skip (4 bytes)**
- 3-byte RGB and 2-byte gray+alpha are **not** valid CGContext configurations — render to a supported intermediate (RGBX or RGBA) and convert
- Use integer arithmetic for BT.601 luminance (`299*R + 587*G + 114*B`) to avoid floating-point boundary errors

## SPM Dependencies
- `libjpeg` (SusanDoggie/libjpeg) — JPEG region decode
- `libjxl` (SDWebImage/libjxl-Xcode) — JXL JPEG reconstruction
