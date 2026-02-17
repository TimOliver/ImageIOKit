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
- `ImageDestination.condition` transcodes non-JPEG sources to JPEG on disk, giving them shrink-on-load and region decode for free

## Key Classes
- `ImageSource` — public facade wrapping `CGImageSource`. Decode, thumbnail, region decode, JPEG reconstruction. Caches full-resolution `CGImage` via `NSCache` (purgeable under memory pressure).
- `ImageDestination` — encode/write/condition/transcode via `CGImageDestination`. Accepts `CGImage` directly.
- `JPEGRegionDecoder` — libjpeg `crop_scanline` for JPEG-only tile decode
- `JXLReconstructor` — libjxl JPEG bitstream reconstruction for JXL-from-JPEG sources
- `TileManager` — on-demand tile decode with `NSCache`. JPEG tiles via parallel region decode; all other formats via `CGImage.cropping(to:)` on the cached full decode.
- `PixelBuffer` — C-allocated pixel data with zero-copy `CGImage` via retained `CGDataProvider`

## SPM Dependencies
- `libjpeg` (SusanDoggie/libjpeg) — JPEG region decode
- `libjxl` (SDWebImage/libjxl-Xcode) — JXL JPEG reconstruction
