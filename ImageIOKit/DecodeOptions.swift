//
//  DecodeOptions.swift
//  ImageIOKit
//

import Foundation
import CoreGraphics

/// Options that control how an image is decoded.
public struct DecodeOptions {

    /// Target output size. The decoder will attempt to produce an image
    /// close to this size using the most efficient method available.
    /// Pass `nil` for full-resolution decode.
    public var targetSize: CGSize?

    /// Region of the full image to decode, in pixel coordinates.
    /// For JPEG sources, this uses native region decode (libjpeg crop_scanline).
    /// For others, the full image is decoded then cropped.
    /// Pass `nil` to decode the entire image.
    public var cropRect: CGRect?

    /// Desired pixel format for the output buffer.
    public var pixelFormat: PixelBuffer.PixelFormat

    public init(targetSize: CGSize? = nil, cropRect: CGRect? = nil,
                pixelFormat: PixelBuffer.PixelFormat = .rgba8) {
        self.targetSize = targetSize
        self.cropRect = cropRect
        self.pixelFormat = pixelFormat
    }
}
