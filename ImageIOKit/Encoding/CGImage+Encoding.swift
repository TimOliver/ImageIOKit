//
//  CGImage+Encoding.swift
//  ImageIOKit
//
//  Encode/write extensions on CGImage; condition/transcode extensions on ImageSource.
//  All encoding via Apple's CGImageDestination.
//

import Foundation
import ImageIO
import CoreGraphics

// MARK: - CGImage encode / write

public extension CGImage {

    /// Encode to the specified format.
    /// - Parameters:
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality).
    /// - Returns: The encoded image data.
    func encode(as format: ImageFileFormat,
                options: EncodeOptions = EncodeOptions()) throws -> Data {
        let finalImage = format.isOpaque ? strippingAlpha() : self
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
    ///   - url: The file URL to write to.
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality).
    func write(to url: URL, as format: ImageFileFormat,
               options: EncodeOptions = EncodeOptions()) throws {
        let finalImage = format.isOpaque ? strippingAlpha() : self
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

    // MARK: Private

    /// Returns the image with alpha stripped if it has an alpha channel.
    /// No-op if the image is already opaque.
    private func strippingAlpha() -> CGImage {
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

