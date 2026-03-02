//
//  ImageSource+Decoding.swift
//  ImageIOKit
//
//  Decode operations for ImageSource: thumbnail generation, region decode,
//  full decode, and raw pixel-buffer decode.
//

import Foundation
import CoreGraphics
import ImageIO
import UIKit

// MARK: - Thumbnail Generation

extension ImageSource {

    /// Generates a downscaled copy of the original image, optimistically avoiding decoding
    /// the whole original image into memory if possible.
    /// - Parameter size: The preferred bounding size that the thumbnail will scale to fit in.
    /// - Returns: The downscaled image if successful, nil otherwise.
    public func makeThumbnail(fittingSize size: CGSize) -> UIImage? {
        guard isLoaded else { return nil }

        // JXL: decode via libjxl callback decoder for lower peak memory,
        // then scale down to the requested thumbnail size.
        if fileFormat == .jpegXL {
            if let thumbnail = makeJXLThumbnail(fittingSize: size) {
                return thumbnail
            }
        }

        guard let cgImageSource else { return nil }

        let maxDimension = max(size.width, size.height)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Decodes a JXL image via libjxl's DC-only progressive decode and scales
    /// it down to fit within the given bounding size.
    ///
    /// For VarDCT images, only the DC coefficients (1/8th resolution) are decoded,
    /// saving ~98% of decode memory. The small result is then scaled to the exact
    /// target size via CGContext.
    private func makeJXLThumbnail(fittingSize size: CGSize) -> UIImage? {
        let decoder: JXLDecoder?
        if let url {
            decoder = JXLDecoder(url: url)
        } else if let data {
            decoder = JXLDecoder(data: data)
        } else {
            return nil
        }

        guard let decoder,
              let pixelBuffer = try? decoder.decodeThumbnail(fittingSize: size),
              let dcImage = pixelBuffer.makeCGImage() else {
            return nil
        }

        // Compute the scaled size that fits within the bounding box
        let imageWidth = CGFloat(pixelBuffer.width)
        let imageHeight = CGFloat(pixelBuffer.height)
        let scale = min(size.width / imageWidth, size.height / imageHeight)
        // If the DC image already fits, return it directly
        if scale >= 1.0 {
            return UIImage(cgImage: dcImage)
        }

        let targetWidth = Int((imageWidth * scale).rounded())
        let targetHeight = Int((imageHeight * scale).rounded())

        // Scale via CGContext
        guard let colorSpace = dcImage.colorSpace,
              let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(dcImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = ctx.makeImage() else { return nil }
        return UIImage(cgImage: scaled)
    }
}

// MARK: - Region Decode

extension ImageSource {

    /// Decodes a specific region of the image, using native region decode when available.
    /// - Parameter rect: The region to decode, in pixel coordinates of the full image.
    /// - Parameter targetSize: Optional target size for the decoded region.
    /// - Returns: The decoded region as a UIImage, or nil on failure.
    public func decodeRegion(_ rect: CGRect, targetSize: CGSize? = nil) -> UIImage? {
        guard isLoaded else { return nil }

        // JPEG: use libjpeg native region decode
        if fileFormat == .jpeg {
            let regionDecoder: JPEGRegionDecoder?
            if let url {
                regionDecoder = JPEGRegionDecoder(url: url)
            } else if let data {
                regionDecoder = JPEGRegionDecoder(data: data)
            } else {
                return nil
            }

            guard let regionDecoder,
                  let pixelBuffer = try? regionDecoder.decodeRegion(cropRect: rect, targetSize: targetSize),
                  let cgImage = pixelBuffer.makeCGImage() else { return nil }
            return UIImage(cgImage: cgImage)
        }

        // All other formats: full decode via ImageIO + CGImage.cropping
        guard let fullImage = decodeFullCGImage() else { return nil }

        // Clamp the rect to the image bounds
        let clampedRect = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clampedRect.isEmpty,
              let cropped = fullImage.cropping(to: clampedRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

// MARK: - Full Decode

extension ImageSource {

    /// Decodes the full image at its original resolution.
    /// - Returns: The decoded image as a UIImage, or nil on failure.
    public func decodeFullImage() -> UIImage? {
        guard let cgImage = decodeFullCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Decodes the full image and returns a CGImage. The result is cached so
    /// that repeated calls (e.g. tiling multiple regions) reuse the same decode.
    /// The cache is purgeable under memory pressure.
    public func decodeFullCGImage() -> CGImage? {
        if let cached = fullDecodeCache.object(forKey: ImageSource.fullDecodeCacheKey) {
            return cached
        }

        guard let cgImageSource, isLoaded else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return nil
        }
        fullDecodeCache.setObject(image, forKey: ImageSource.fullDecodeCacheKey)
        return image
    }
}

// MARK: - Raw Decode Access

extension ImageSource {

    /// Decodes the image and returns the raw pixel buffer.
    /// This is the lowest-level decode method, suitable for custom processing pipelines.
    /// - Parameters:
    ///   - targetSize: Target output size. The decoder will produce an image close to this
    ///     size using the most efficient method available. Pass `nil` for full-resolution decode.
    ///   - cropRect: Region of the full image to decode, in pixel coordinates.
    ///     For JPEG sources, this uses native region decode (libjpeg crop_scanline).
    ///     For others, the full image is decoded then cropped. Pass `nil` to decode the entire image.
    ///   - pixelFormat: Desired pixel format for the output buffer.
    /// - Returns: A pixel buffer containing the decoded image data.
    /// - Throws: `ImageDecoderError` on failure.
    public func decode(
        targetSize: CGSize? = nil,
        cropRect: CGRect? = nil,
        pixelFormat: PixelBuffer.PixelFormat = .rgba8
    ) throws -> PixelBuffer {
        guard let cgImageSource, isLoaded else {
            throw ImageDecoderError.invalidData
        }

        // Determine the CGImage to work with
        let cgImage: CGImage

        if let targetSize, cropRect == nil {
            // Use thumbnailing for downscaled decode
            let maxDimension = max(targetSize.width, targetSize.height)
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, thumbOptions as CFDictionary) else {
                throw ImageDecoderError.decodeFailed("CGImageSourceCreateThumbnailAtIndex failed")
            }
            cgImage = thumb
        } else {
            // Full decode
            let fullOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let full = CGImageSourceCreateImageAtIndex(cgImageSource, 0, fullOptions as CFDictionary) else {
                throw ImageDecoderError.decodeFailed("CGImageSourceCreateImageAtIndex failed")
            }
            cgImage = full
        }

        // Apply crop if requested
        var workingImage = cgImage
        if let cropRect {
            guard let cropped = cgImage.cropping(to: cropRect) else {
                throw ImageDecoderError.invalidOptions("Crop rect \(cropRect) is out of bounds")
            }
            workingImage = cropped

            // If target size was also requested, scale via a second thumbnail pass
            if let targetSize {
                let fitSize = SoftwareScaler.fittingSize(
                    for: CGSize(width: workingImage.width, height: workingImage.height),
                    in: targetSize
                )
                workingImage = try renderToSize(workingImage, size: fitSize)
            }
        }

        // Render CGImage into a PixelBuffer
        return try renderToPixelBuffer(workingImage, pixelFormat: pixelFormat)
    }

    // MARK: - Private Helpers

    /// Renders a CGImage into a new CGImage at the specified size.
    private func renderToSize(_ image: CGImage, size: CGSize) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else {
            throw ImageDecoderError.invalidOptions("Target size is zero")
        }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else {
            throw ImageDecoderError.decodeFailed("Failed to create CGContext for scaling")
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let result = ctx.makeImage() else {
            throw ImageDecoderError.decodeFailed("Failed to create scaled CGImage")
        }
        return result
    }

    /// Renders a CGImage into a PixelBuffer with the requested pixel format.
    private func renderToPixelBuffer(_ image: CGImage, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        let width = image.width
        let height = image.height
        let buffer = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
        let drawRect = CGRect(x: 0, y: 0, width: width, height: height)

        // CGContext at 8bpc only supports gray/1-byte and RGBA/RGBX/4-byte.
        // For rgb8 and grayAlpha8 we render to a supported intermediate and convert.
        switch pixelFormat {
        case .gray8:
            guard let ctx = CGContext(
                data: buffer.data, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

        case .rgba8:
            guard let ctx = CGContext(
                data: buffer.data, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

        case .rgb8:
            // Render to RGBX (4 bytes/pixel), then strip the padding byte
            let tempBytesPerRow = width * 4
            let tempData = UnsafeMutableRawPointer.allocate(byteCount: tempBytesPerRow * height, alignment: 16)
            defer { tempData.deallocate() }

            guard let ctx = CGContext(
                data: tempData, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: tempBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

            let src = tempData.assumingMemoryBound(to: UInt8.self)
            let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let s = row * tempBytesPerRow + col * 4
                    let d = row * buffer.bytesPerRow + col * 3
                    dst[d] = src[s]; dst[d+1] = src[s+1]; dst[d+2] = src[s+2]
                }
            }

        case .grayAlpha8:
            // Render to RGBA (4 bytes/pixel), then convert to luminance + alpha
            let tempBytesPerRow = width * 4
            let tempData = UnsafeMutableRawPointer.allocate(byteCount: tempBytesPerRow * height, alignment: 16)
            defer { tempData.deallocate() }

            guard let ctx = CGContext(
                data: tempData, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: tempBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

            let src = tempData.assumingMemoryBound(to: UInt8.self)
            let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let s = row * tempBytesPerRow + col * 4
                    let d = row * buffer.bytesPerRow + col * 2
                    let gray = (299 * Int(src[s]) + 587 * Int(src[s+1]) + 114 * Int(src[s+2])) / 1000
                    dst[d] = UInt8(gray); dst[d+1] = src[s+3]
                }
            }
        }

        return buffer
    }
}
