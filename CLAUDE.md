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

## Architecture Direction
- Wrap Apple's ImageIO for all decode and thumbnail operations (fast, multi-threaded, hardware-accelerated)
- Keep libjpeg only for JPEG region decode (crop_scanline) needed by tile-based zoom
- `ImageDestination.condition` transcodes non-JPEG sources to JPEG on disk, giving them shrink-on-load and region decode for free
