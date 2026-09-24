//
//  ImageSource+Encoding.swift
//  ImageIOKit
//
//  ImageIO encoding, conditioned JPEG writing, and lossless JXL reconstruction.
//

import Foundation
import ImageIO
import CoreGraphics

// MARK: - ImageSource encode / write

public extension ImageSource {

    /// Encode to the specified format.
    ///
    /// ImageIO manages decoding and encoding through `CGImageDestinationAddImageFromSource`
    /// when no explicit alpha conversion is required. This is not a byte-preserving copy.
    ///
    /// - Parameters:
    ///   - format: The target image file format.
    ///   - quality: Compression quality from 0.0 (smallest file) to 1.0 (best quality). Default is 0.85.
    /// - Returns: The encoded image data.
    func encoded(as format: ImageFileFormat,
                quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for \(format)")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
        ]
        try addImage(to: dest, format: format, properties: properties)

        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed")
        }
        return data as Data
    }

    /// Encode and write to disk.
    ///
    /// ImageIO manages the conversion; this can decode and re-encode the image.
    ///
    /// - Parameters:
    ///   - url: The file URL to write to.
    ///   - format: The target image file format.
    ///   - quality: Compression quality from 0.0 (smallest file) to 1.0 (best quality). Default is 0.85.
    func write(to url: URL, as format: ImageFileFormat,
               quality: Double = 0.85) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for \(format)")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
        ]
        try addImage(to: dest, format: format, properties: properties)

        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed for \(url)")
        }
    }
}

// MARK: - ImageSource conditioning / transcode

public extension ImageSource {

    /// Produces a JPEG file optimized for efficient partial decoding.
    ///
    /// - If the source is already JPEG and fits within `maxDimension`, writes
    ///   a byte-identical copy without re-encoding (quality is ignored).
    /// - For JXL-from-JPEG sources that fit within `maxDimension`, writes the
    ///   losslessly reconstructed JPEG to `url` (zero quality loss).
    /// - Otherwise, decodes at a resolution capped to `maxDimension`
    ///   (preserving aspect ratio), encodes as JPEG, and writes to `url`.
    ///
    /// Always returns a source pointing to the destination file on success.
    /// The caller decides where to write and when to clean up.
    ///
    /// - Parameters:
    ///   - maxDimension: The maximum allowed length of the image's longest edge in pixels.
    ///                   Images larger than this are downscaled (preserving aspect ratio)
    ///                   before encoding. Defaults to 4096.
    ///   - url: The file URL to write the conditioned JPEG to.
    ///   - quality: Compression quality from 0.0 (smallest) to 1.0 (best). Default is 0.85.
    func writeConditionedJPEG(maxDimension: Int = 4096,
                              to url: URL,
                              quality: Double = 0.85) throws -> ImageSource {
        guard isLoaded, maxDimension > 0, url.isFileURL else {
            throw ImageEncoderError.encodeFailed("Conditioning requires a loaded source, a positive dimension, and a file URL")
        }
        let maxDim = CGFloat(maxDimension)
        let longEdge = max(imageSize.width, imageSize.height)

        // Copy compressed bytes atomically, including when the destination is the source.
        if fileFormat == .jpeg && longEdge <= maxDim {
            let compressed: Data
            if let data { compressed = data }
            else if let sourceURL = self.url { compressed = try Data(contentsOf: sourceURL, options: .mappedIfSafe) }
            else { throw ImageEncoderError.encodeFailed("Missing JPEG source") }
            try compressed.write(to: url, options: .atomic)
            guard let written = ImageSource(url: url) else {
                throw ImageEncoderError.encodeFailed("Failed to load copied JPEG")
            }
            return written
        }

        // JXL → lossless JPEG reconstruction avoids the expensive full JXL decode.
        // If the reconstructed JPEG is oversized, thumbnail it via ImageIO.
        if fileFormat == .jpegXL, let jpegData = reconstructJPEGfromJPEGXL() {
            if longEdge <= maxDim {
                // Fits — write reconstructed JPEG directly
                try jpegData.write(to: url, options: .atomic)
                guard let conditioned = ImageSource(url: url) else {
                    throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG from JXL reconstruction")
                }
                return conditioned
            }

            // Oversized — thumbnail the reconstructed JPEG via ImageIO
            guard let jpegSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
                throw ImageEncoderError.encodeFailed("Failed to create CGImageSource from reconstructed JPEG")
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(jpegSource, 0, thumbOptions as CFDictionary) else {
                throw ImageEncoderError.encodeFailed("Failed to create thumbnail from reconstructed JPEG")
            }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, ImageFileFormat.jpeg.uniformTypeIdentifier, 1, nil) else {
                throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for conditioned JPEG")
            }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
            ]
            CGImageDestinationAddImage(dest, thumb, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed for conditioned JPEG")
            }
            guard let conditioned = ImageSource(url: url) else {
                throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
            }
            return conditioned
        }

        // General path: thumbnail via ImageIO (capped to maxDimension), encode as JPEG
        guard let cgSource = cgImageSource else {
            throw ImageEncoderError.encodeFailed("Failed to obtain CGImageSource for conditioning")
        }

        let dest: CGImageDestination
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, ImageFileFormat.jpeg.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for conditioning")
        }
        dest = d

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
        ]

        if longEdge > maxDim {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, thumbOptions as CFDictionary) else {
                throw ImageEncoderError.encodeFailed("Failed to create thumbnail for conditioning")
            }
            CGImageDestinationAddImage(dest, thumb, properties as CFDictionary)
        } else {
            // Fits but not JPEG — transcode via source-to-destination copy
            CGImageDestinationAddImageFromSource(dest, cgSource, 0, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed for conditioning")
        }

        guard let conditioned = ImageSource(url: url) else {
            throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
        }
        return conditioned
    }

    /// Decode from this image source and re-encode to a target format (convenience transcode).
    ///
    /// When transcoding JXL → JPEG, this automatically attempts JPEG bitstream
    /// reconstruction first. If the JXL was created from a JPEG, the exact original
    /// JPEG is returned with zero quality loss and no decode/re-encode overhead.
    ///
    /// - Parameters:
    ///   - format: The target image file format.
    ///   - quality: Compression quality from 0.0 (smallest) to 1.0 (best). Default is 0.85.
    /// - Returns: The transcoded image data.
    func transcoded(to format: ImageFileFormat,
                   quality: Double = 0.85) throws -> Data {
        // Fast path: JXL → JPEG via lossless bitstream reconstruction
        if format == .jpeg, fileFormat == .jpegXL,
           let jpegData = reconstructJPEGfromJPEGXL() {
            return jpegData
        }

        return try encoded(as: format, quality: quality)
    }

    // MARK: - JPEG Reconstruction

    /// For JXL images that were created by losslessly recompressing a JPEG,
    /// reconstructs the exact original JPEG bitstream. Returns `nil` if the
    /// source is not JXL or was not derived from a JPEG.
    func reconstructJPEGfromJPEGXL() -> Data? {
        guard fileFormat == .jpegXL else { return nil }

        let reconstructor: JXLReconstructor?
        if let url {
            reconstructor = JXLReconstructor(url: url)
        } else if let data {
            reconstructor = JXLReconstructor(data: data)
        } else {
            return nil
        }

        return reconstructor?.reconstructJPEG()
    }
}

// MARK: - Private

private extension ImageSource {

    /// Adds the image to a CGImageDestination, using the fast source-to-destination
    /// path when no alpha stripping is needed, otherwise falling back to a decoded CGImage.
    func addImage(to dest: CGImageDestination,
                  format: ImageFileFormat,
                  properties: [CFString: Any]) throws {
        // Let ImageIO manage conversion when no explicit alpha strip is needed.
        if !format.isOpaque || !hasAlpha, let source = cgImageSource {
            CGImageDestinationAddImageFromSource(dest, source, 0, properties as CFDictionary)
            return
        }

        // Fallback: decode and strip alpha
        guard let cgImage = decodeFullCGImage() else {
            throw ImageEncoderError.encodeFailed("Failed to decode source image for encoding")
        }
        CGImageDestinationAddImage(dest, cgImage.strippingAlpha(), properties as CFDictionary)
    }
}

private extension CGImage {

    /// Returns the image with alpha stripped if it has an alpha channel.
    /// No-op if the image is already opaque.
    func strippingAlpha() -> CGImage {
        let alpha = alphaInfo
        guard alpha != .none, alpha != .noneSkipFirst, alpha != .noneSkipLast else {
            return self
        }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return self
        }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? self
    }
}
