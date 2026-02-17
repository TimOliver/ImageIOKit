//
//  ImageDecoder.swift
//  ImageIOKit
//
//  Shared types used by image decode operations:
//  DecodeOptions, ImageMetadata, DecoderCapabilities, and errors.
//

import Foundation
import CoreGraphics

// MARK: - Decode Options

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

// MARK: - Image Metadata

/// Lightweight metadata read from the image header without full decoding.
public struct ImageMetadata {
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

// MARK: - Decoder Capabilities

/// Describes the native decode capabilities of a source.
public struct DecoderCapabilities: OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The source can decode a sub-region without decoding the full image
    /// (JPEG via libjpeg crop_scanline).
    public static let regionDecode = DecoderCapabilities(rawValue: 1 << 1)
}

// MARK: - Errors

/// Errors produced by image decode operations.
public enum ImageDecoderError: Error {
    /// The input data is not a valid image.
    case invalidData
    /// The decode operation failed. The associated string provides details.
    case decodeFailed(String)
    /// The requested operation is not supported.
    case unsupportedOperation
    /// The provided decode options are invalid (e.g., crop rect out of bounds).
    case invalidOptions(String)
}
