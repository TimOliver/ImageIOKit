//
//  ImageMetadata.swift
//  ImageIOKit
//

import Foundation
import CoreGraphics

/// Lightweight metadata read from the image header without full decoding.
public struct    {
    /// Full image width in pixels.
    public let width: Int
    /// Full image height in pixels.
    public let height: Int
    /// Whether the image contains an alpha channel.
    public let hasAlpha: Bool
    /// The color model (RGB, grayscale, etc.) if determinable.
    public let colorModel: ImageColorModel?
    /// ICC profile name, if present.
    public let colorProfile: String?

    /// Convenience accessor for the full image size.
    public var size: CGSize { CGSize(width: width, height: height) }

    public init(width: Int, height: Int, hasAlpha: Bool,
                colorModel: ImageColorModel? = nil, colorProfile: String? = nil) {
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
        self.colorModel = colorModel
        self.colorProfile = colorProfile
    }
}
