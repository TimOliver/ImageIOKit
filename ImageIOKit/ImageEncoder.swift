//
//  ImageEncoder.swift
//  ImageIOKit
//
//  Defines the protocol for format-specific image encoders,
//  along with shared encode options and error types.
//

import Foundation

// MARK: - Encode Options

/// Options that control how an image is encoded.
public struct EncodeOptions {

    /// Compression quality from 0.0 (smallest file) to 1.0 (best quality).
    /// Default is 0.85. Ignored when `lossless` is true.
    public var quality: Double

    /// Whether to encode losslessly. Default is false.
    /// Always true for PNG. Honored by WebP and JXL. Ignored by JPEG and AVIF.
    public var lossless: Bool

    /// Encoding speed from 0 (slowest/best compression) to 10 (fastest/largest).
    /// Default is 5. Interpretation varies by format.
    public var speed: Int

    public init(quality: Double = 0.85, lossless: Bool = false, speed: Int = 5) {
        self.quality = max(0.0, min(1.0, quality))
        self.lossless = lossless
        self.speed = max(0, min(10, speed))
    }
}

// MARK: - Errors

/// Errors produced by image encoders.
public enum ImageEncoderError: Error {
    /// The encode operation failed. The associated string provides details.
    case encodeFailed(String)
    /// The pixel format of the input buffer is not supported by this encoder.
    case unsupportedPixelFormat
}

// MARK: - Protocol

/// A format-specific image encoder that compresses a `PixelBuffer` into encoded data.
public protocol ImageEncoder {
    /// The file format this encoder produces.
    static var format: ImageFileFormat { get }
    /// Whether this encoder can preserve alpha channel data.
    static var supportsAlpha: Bool { get }
    /// Whether this encoder supports lossless compression.
    static var supportsLossless: Bool { get }
    /// Encodes the given pixel buffer with the specified options.
    func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data
}
