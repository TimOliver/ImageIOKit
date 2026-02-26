//
//  ImageDestination.swift
//  ImageIOKit
//
//  Wraps Apple's CGImageDestination for encoding images.
//  Provides encode, write, condition, and transcode operations.
//

import Foundation
import ImageIO
import CoreGraphics

public final class ImageDestination {

    /// Encode a CGImage to the specified format.
    /// - Parameters:
    ///   - image: The image to encode.
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality).
    /// - Returns: The encoded image data.
    public static func encode(_ image: CGImage, format: ImageFileFormat,
                              options: EncodeOptions = EncodeOptions()) throws -> Data {
        let finalImage = format.isOpaque ? Self.strippingAlpha(from: image) : image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for \(format)")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: options.quality
        ]
        CGImageDestinationAddImage(dest, finalImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed")
        }
        return data as Data
    }

    /// Encode and write to disk.
    /// - Parameters:
    ///   - image: The image to encode.
    ///   - url: The file URL to write to.
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality).
    public static func write(_ image: CGImage, to url: URL, format: ImageFileFormat,
                             options: EncodeOptions = EncodeOptions()) throws {
        let finalImage = format.isOpaque ? Self.strippingAlpha(from: image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageDestination for \(format)")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: options.quality
        ]
        CGImageDestinationAddImage(dest, finalImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncoderError.encodeFailed("CGImageDestinationFinalize failed for \(url)")
        }
    }

    // MARK: - Private

    /// Returns the image with alpha stripped if it has an alpha channel.
    /// No-op if the image is already opaque.
    private static func strippingAlpha(from image: CGImage) -> CGImage {
        let alpha = image.alphaInfo
        guard alpha != .none, alpha != .noneSkipFirst, alpha != .noneSkipLast else {
            return image
        }
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Produces a JPEG file optimized for efficient partial decoding.
    ///
    /// - If the source is already JPEG and fits within `maxDimension`, returns
    ///   the original source unchanged (no work done).
    /// - For JXL-from-JPEG sources that fit within `maxDimension`, writes the
    ///   losslessly reconstructed JPEG to `url` (zero quality loss).
    /// - Otherwise, decodes at a resolution capped to `maxDimension`
    ///   (preserving aspect ratio), encodes as JPEG, and writes to `url`.
    ///
    /// The caller decides where to write and when to clean up.
    ///
    /// - Parameters:
    ///   - source: The image source to condition.
    ///   - maxDimension: The maximum allowed length of the image's longest edge in pixels.
    ///                   Images larger than this are downscaled (preserving aspect ratio)
    ///                   before encoding. Defaults to 4096.
    ///   - url: The file URL to write the conditioned JPEG to.
    ///   - encodeOptions: Options for JPEG encoding (quality). Defaults to standard quality.
    public static func condition(_ source: ImageSource,
                                 maxDimension: Int = 4096,
                                 to url: URL,
                                 encodeOptions: EncodeOptions = EncodeOptions()) throws -> ImageSource {
        let maxDim = CGFloat(maxDimension)
        let longEdge = max(source.imageSize.width, source.imageSize.height)

        // Fast path: already JPEG and fits — no work needed
        if source.fileFormat == .jpeg && longEdge <= maxDim {
            return source
        }

        // JXL → lossless JPEG reconstruction avoids the expensive full JXL decode.
        // If the reconstructed JPEG is oversized, thumbnail it via ImageIO.
        if source.fileFormat == .jpegXL, let jpegData = source.reconstructJPEG() {
            if longEdge <= maxDim {
                // Fits — write reconstructed JPEG directly
                try jpegData.write(to: url)
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
            try write(thumb, to: url, format: .jpeg, options: encodeOptions)
            guard let conditioned = ImageSource(url: url) else {
                throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
            }
            return conditioned
        }

        // General path: thumbnail via ImageIO (capped to maxDimension), encode as JPEG
        guard let cgSource = CGImageSourceCreateWithURL((source.url ?? url) as CFURL, nil)
                ?? (source.data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageSource for conditioning")
        }

        let cgImage: CGImage
        if longEdge > maxDim {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, thumbOptions as CFDictionary) else {
                throw ImageEncoderError.encodeFailed("Failed to create thumbnail for conditioning")
            }
            cgImage = thumb
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else {
                throw ImageEncoderError.encodeFailed("Failed to decode image for conditioning")
            }
            cgImage = full
        }

        try write(cgImage, to: url, format: .jpeg, options: encodeOptions)

        guard let conditioned = ImageSource(url: url) else {
            throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
        }
        return conditioned
    }

    /// Decode from an image source and re-encode to a target format (convenience transcode).
    ///
    /// When transcoding JXL → JPEG, this automatically attempts JPEG bitstream
    /// reconstruction first. If the JXL was created from a JPEG, the exact original
    /// JPEG is returned with zero quality loss and no decode/re-encode overhead.
    ///
    /// - Parameters:
    ///   - source: The image source to decode from.
    ///   - format: The target image file format.
    ///   - encodeOptions: Options for encoding to the target format.
    /// - Returns: The transcoded image data.
    public static func transcode(from source: ImageSource, to format: ImageFileFormat,
                                 encodeOptions: EncodeOptions = EncodeOptions()) throws -> Data {
        // Fast path: JXL → JPEG via lossless bitstream reconstruction
        if format == .jpeg, source.fileFormat == .jpegXL,
           let jpegData = source.reconstructJPEG() {
            return jpegData
        }

        guard let cgImage = source.decodeFullCGImage() else {
            throw ImageEncoderError.encodeFailed("Failed to decode source image for transcoding")
        }
        return try encode(cgImage, format: format, options: encodeOptions)
    }
}
