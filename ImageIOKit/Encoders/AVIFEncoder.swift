//
//  AVIFEncoder.swift
//  ImageIOKit
//
//  AVIF encoder using avif.swift (awxkee/avif.swift).
//  Wraps avif.AVIFEncoder (fully qualified to avoid collision with this type).
//

import Foundation
import CoreGraphics
import UIKit
import avif

public final class AVIFEncoder: ImageEncoder {

    public static let format: ImageFileFormat = .avif
    public static let supportsAlpha = true
    public static let supportsLossless = false

    public init() {}

    public func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data {
        // avif.swift expects a UIImage, so convert PixelBuffer → CGImage → UIImage
        guard let cgImage = buffer.makeCGImage() else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImage from PixelBuffer")
        }
        let image = UIImage(cgImage: cgImage)

        // Map speed 0–10 → avif.swift speed parameter (-1 = auto, or 0–10)
        // Our 0 = slowest/best, 10 = fastest; avif.swift uses same convention
        let avifSpeed = options.speed

        do {
            return try avif.AVIFEncoder.encode(
                image: image,
                quality: options.quality,
                speed: avifSpeed
            )
        } catch {
            throw ImageEncoderError.encodeFailed("AVIF encode failed: \(error.localizedDescription)")
        }
    }
}
