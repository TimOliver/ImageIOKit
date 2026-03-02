//
//  SoftwareScaler.swift
//  ImageIOKit
//
//  Utility for geometry calculations and PixelBuffer cropping.
//  Scaling is handled by ImageIO's thumbnailing; only crop and
//  aspect-ratio fitting remain here.
//

import Foundation
import CoreGraphics

enum SoftwareScaler {

    /// Crops a pixel buffer to the given rect.
    /// - Parameters:
    ///   - source: The pixel buffer to crop.
    ///   - rect: The crop region in pixel coordinates of the source.
    /// - Returns: A new pixel buffer containing the cropped region, or `nil` if out of bounds.
    static func crop(_ source: PixelBuffer, to rect: CGRect) -> PixelBuffer? {
        let x = Int(rect.origin.x)
        let y = Int(rect.origin.y)
        let cropWidth = Int(rect.width)
        let cropHeight = Int(rect.height)

        guard x >= 0, y >= 0, cropWidth > 0, cropHeight > 0,
              x + cropWidth <= source.width, y + cropHeight <= source.height else { return nil }

        let bpp = source.pixelFormat.bytesPerPixel
        let destBytesPerRow = cropWidth * bpp
        let dest = PixelBuffer(width: cropWidth, height: cropHeight, pixelFormat: source.pixelFormat)

        for row in 0..<cropHeight {
            let srcOffset = (y + row) * source.bytesPerRow + x * bpp
            let dstOffset = row * destBytesPerRow
            memcpy(dest.data.advanced(by: dstOffset),
                   source.data.advanced(by: srcOffset),
                   destBytesPerRow)
        }
        return dest
    }

    /// Computes the best fitting size that preserves aspect ratio within a bounding box.
    /// - Parameters:
    ///   - imageSize: The original image dimensions.
    ///   - boundingSize: The maximum bounding box to fit within.
    /// - Returns: The largest size that fits inside `boundingSize` while preserving aspect ratio.
    static func fittingSize(for imageSize: CGSize, in boundingSize: CGSize) -> CGSize {
        let scale = min(boundingSize.width / imageSize.width,
                        boundingSize.height / imageSize.height)
        return CGSize(width: (imageSize.width * scale).rounded(.down),
                      height: (imageSize.height * scale).rounded(.down))
    }
}
