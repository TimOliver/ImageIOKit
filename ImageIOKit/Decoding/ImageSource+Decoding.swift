//
//  ImageSource+Decoding.swift
//  ImageIOKit
//

import Foundation
import CoreGraphics
import ImageIO

extension ImageSource {

    /// Returns an upright thumbnail fitting both bounds, without upscaling.
    public func makeThumbnail(fittingSize size: CGSize) -> PlatformImage? {
        guard let image = try? thumbnailCGImage(fitting: size) else { return nil }
        return PlatformImage.wrapping(image)
    }

    /// Decodes a region in upright display-pixel coordinates (origin at top left).
    /// The crop is rounded outward to whole pixels and clamped to `imageSize`.
    /// `targetSize` is an optional bounding box; results are never upscaled.
    public func decodeRegion(_ rect: CGRect, targetSize: CGSize? = nil) -> PlatformImage? {
        guard let buffer = try? decode(targetSize: targetSize, cropRect: rect),
              let image = buffer.makeCGImage() else { return nil }
        return PlatformImage.wrapping(image)
    }

    /// Decodes the full image with its orientation applied to the pixels.
    public func decodeFullImage() -> PlatformImage? {
        guard let image = decodeFullCGImage() else { return nil }
        return PlatformImage.wrapping(image)
    }

    /// Returns an upright full-resolution image. The result is cached and purgeable.
    public func decodeFullCGImage() -> CGImage? {
        let key = Self.fullDecodeCacheKey as NSString
        if let cached = fullDecodeCache.object(forKey: key) { return cached }
        guard isLoaded, let cgImageSource else { return nil }

        let image: CGImage?
        if orientation == .up {
            image = CGImageSourceCreateImageAtIndex(cgImageSource, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            // A full-size ImageIO thumbnail applies all eight EXIF transforms.
            image = try? imageIOThumbnail(fitting: imageSize)
        }
        guard let image else { return nil }
        fullDecodeCache.setObject(image, forKey: key)
        return image
    }

    /// Decodes upright pixels. RGB output is sRGB; alpha is premultiplied.
    /// - Parameters:
    ///   - targetSize: Bounding box for the output, preserving aspect ratio without upscaling.
    ///   - cropRect: Region in upright display pixels, rounded outward and clamped to `imageSize`.
    ///     Upright JPEGs and supported still WebP crops use native decoding;
    ///     other inputs use full decode then crop.
    ///   - pixelFormat: Desired output layout. Opaque formats composite transparency over black.
    public func decode(targetSize: CGSize? = nil, cropRect: CGRect? = nil,
                       pixelFormat: PixelBuffer.PixelFormat = .rgba8) throws -> PixelBuffer {
        guard isLoaded else { throw ImageDecoderError.invalidData }
        let crop = try cropRect.map { try SoftwareScaler.clampedCrop($0, in: imageSize) }
        let size = try SoftwareScaler.outputSize(for: crop?.size ?? imageSize, fitting: targetSize)

        if let buffer = try nativeWebP(targetSize: targetSize, cropRect: crop) {
            return try finish(buffer, size: size, pixelFormat: pixelFormat)
        }

        if isRegionDecodable, let crop {
            let decoder = url.flatMap { JPEGRegionDecoder(url: $0) }
                ?? data.flatMap { JPEGRegionDecoder(data: $0) }
            if let region = try? decoder?.decodeRegion(cropRect: crop, targetSize: size) {
                return try finish(region, size: size, pixelFormat: pixelFormat)
            }
        }

        let image: CGImage
        if let crop {
            guard let full = decodeFullCGImage(), let cropped = full.cropping(to: crop) else {
                throw ImageDecoderError.decodeFailed("Failed to decode cropped image")
            }
            image = cropped
        } else if targetSize != nil {
            // Native thumbnails are finished directly in the requested format; ImageIO
            // thumbnails are fitted by the single render below rather than rendered twice.
            if let buffer = nativeJXLThumbnail(size: size, pixelFormat: pixelFormat) {
                return try finish(buffer, size: size, pixelFormat: pixelFormat)
            }
            image = try imageIOSubsampledImage(covering: size)
                ?? imageIOThumbnailImage(maxPixelSize: max(size.width, size.height))
        } else {
            guard let full = decodeFullCGImage() else {
                throw ImageDecoderError.decodeFailed("Failed to decode full image")
            }
            image = full
        }
        return try render(image, size: size, pixelFormat: pixelFormat)
    }
}

// Internal helpers, shared with the GPU texture path.
extension ImageSource {

    func thumbnailCGImage(fitting bounds: CGSize) throws -> CGImage {
        guard isLoaded else { throw ImageDecoderError.invalidData }
        let size = try SoftwareScaler.outputSize(for: imageSize, fitting: bounds)
        if let buffer = try nativeWebP(targetSize: bounds),
           let image = try finish(buffer, size: size, pixelFormat: .rgba8).makeCGImage() {
            return image
        }
        if let buffer = nativeJXLThumbnail(size: size, pixelFormat: .rgba8),
           let image = try finish(buffer, size: size, pixelFormat: .rgba8).makeCGImage() {
            return image
        }
        return try imageIOThumbnail(fitting: size)
    }

    /// Decodes JXL thumbnails natively, or returns `nil` to fall back to ImageIO.
    /// Grayscale requests keep grayscale sources in one or two channels.
    func nativeJXLThumbnail(size: CGSize, pixelFormat: PixelBuffer.PixelFormat) -> PixelBuffer? {
        guard fileFormat == .jpegXL else { return nil }
        let decoder = url.flatMap { JXLDecoder(url: $0) } ?? data.flatMap { JXLDecoder(data: $0) }
        let prefersGray = pixelFormat == .gray8 || pixelFormat == .grayAlpha8
        return try? decoder?.decodeThumbnail(fittingSize: size, prefersGrayscale: prefersGray)
    }

    func nativeWebP(targetSize: CGSize?, cropRect: CGRect? = nil) throws -> PixelBuffer? {
        guard fileFormat == .webp, orientation == .up else { return nil }
        let decoder = url.flatMap { WebPImageDecoder(url: $0) } ?? data.flatMap { WebPImageDecoder(data: $0) }
        guard let decoder, decoder.imageSize == imageSize else { return nil }
        do {
            return try decoder.decode(targetSize: targetSize, cropRect: cropRect)
        } catch ImageDecoderError.unsupportedOperation {
            return nil
        }
    }

    /// Returns an upright ImageIO thumbnail fitted to `size`, rendering only if ImageIO overshoots.
    func imageIOThumbnail(fitting size: CGSize) throws -> CGImage {
        if let subsampled = imageIOSubsampledImage(covering: size),
           let result = try render(subsampled, size: size, pixelFormat: .rgba8).makeCGImage() {
            return result
        }
        let image = try imageIOThumbnailImage(maxPixelSize: max(size.width, size.height))
        if image.width <= Int(size.width), image.height <= Int(size.height) { return image }
        guard let result = try render(image, size: size, pixelFormat: .rgba8).makeCGImage() else {
            throw ImageDecoderError.decodeFailed("Failed to create fitted thumbnail")
        }
        return result
    }

    /// For reductions of 4x or more, decodes upright JPEGs at the largest ImageIO subsample factor
    /// (1/4 or 1/8) that still covers `size`, leaving the final resample to CoreGraphics. On iOS,
    /// ImageIO's own thumbnail resampling aliases at large reductions; subsampled decoding still
    /// uses the fast decoder. Smaller reductions keep the thumbnail path, which measured as good
    /// and slightly faster there.
    /// Other formats return `nil`: ImageIO cannot subsample them, so a full decode would replace
    /// the thumbnail path's low-memory streaming. Oriented sources also return `nil`, since a
    /// plain image decode does not apply EXIF transforms.
    /// `factors` lists the subsample factors to try, largest first; include 1 to allow a full decode.
    func imageIOSubsampledImage(covering size: CGSize, factors: [Int] = [8, 4]) -> CGImage? {
        guard fileFormat == .jpeg, orientation == .up, let cgImageSource else { return nil }
        let width = Int(imageSize.width), height = Int(imageSize.height)
        let target = (width: Int(size.width), height: Int(size.height))
        guard let factor = factors.first(where: { width / $0 >= target.width && height / $0 >= target.height }) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceSubsampleFactor: factor,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(cgImageSource, 0, options as CFDictionary),
              image.width >= target.width, image.height >= target.height else { return nil }
        return image
    }

    /// Returns ImageIO's upright thumbnail, which may differ from the fitted size by a pixel.
    func imageIOThumbnailImage(maxPixelSize: CGFloat) throws -> CGImage {
        guard let cgImageSource else { throw ImageDecoderError.invalidData }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, options as CFDictionary) else {
            throw ImageDecoderError.decodeFailed("Failed to create ImageIO thumbnail")
        }
        return image
    }

    func finish(_ buffer: PixelBuffer, size: CGSize, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        if buffer.width == Int(size.width), buffer.height == Int(size.height),
           buffer.pixelFormat == pixelFormat,
           buffer.colorSpace == PixelBuffer.defaultColorSpace(for: pixelFormat) {
            return buffer
        }
        guard let image = buffer.makeCGImage() else {
            throw ImageDecoderError.decodeFailed("Failed to create image from decoded pixels")
        }
        return try render(image, size: size, pixelFormat: pixelFormat)
    }

    /// Resizes and color-converts directly into the final allocation where CGContext permits.
    func render(_ image: CGImage, size: CGSize, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        let width = Int(size.width), height = Int(size.height)
        let output = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
        let needsIntermediate = pixelFormat == .rgb8 || pixelFormat == .grayAlpha8
        let drawable = needsIntermediate ? PixelBuffer(width: width, height: height, pixelFormat: .rgba8) : output
        let alpha: CGImageAlphaInfo = pixelFormat == .gray8 ? .none : .premultipliedLast
        guard let context = CGContext(data: drawable.data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: drawable.bytesPerRow,
                                      space: drawable.colorSpace, bitmapInfo: alpha.rawValue) else {
            throw ImageDecoderError.decodeFailed("Failed to create pixel rendering context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        if needsIntermediate {
            let src = drawable.data.assumingMemoryBound(to: UInt8.self)
            let dst = output.data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let s = row * drawable.bytesPerRow + col * 4
                    let d = row * output.bytesPerRow + col * pixelFormat.bytesPerPixel
                    if pixelFormat == .rgb8 {
                        dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]
                    } else {
                        dst[d] = UInt8((299 * Int(src[s]) + 587 * Int(src[s + 1]) + 114 * Int(src[s + 2])) / 1000)
                        dst[d + 1] = src[s + 3]
                    }
                }
            }
        }
        return output
    }
}
