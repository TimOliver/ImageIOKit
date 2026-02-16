//
//  ImageDecoder.swift
//  ImageIOKit
//
//  Defines the protocol for format-specific image decoders,
//  along with shared option and metadata types.
//

import Foundation
import CoreGraphics

// MARK: - Decode Options

/// Options that control how an image is decoded.
public struct DecodeOptions {

    /// Target output size. The decoder will attempt to produce an image
    /// close to this size using the most efficient method available
    /// (e.g., JPEG 1/2-1/4-1/8 shrink, WebP scaling).
    /// Pass `nil` for full-resolution decode.
    public var targetSize: CGSize?

    /// Region of the full image to decode, in pixel coordinates.
    /// Formats that support native region decode (JPEG, WebP) will
    /// decode only this region. Others will full-decode then crop.
    /// Pass `nil` to decode the entire image.
    public var cropRect: CGRect?

    /// Desired pixel format for the output buffer.
    public var pixelFormat: PixelBuffer.PixelFormat

    /// Maximum bytes the decode operation is allowed to allocate (including
    /// internal codec working memory). When a full decode would exceed this
    /// budget, decoders that support shrink-on-load will fall back to the
    /// largest available reduced-size decode and upscale. Pass 0 (the default)
    /// for no limit.
    public var memoryBudget: Int

    public init(targetSize: CGSize? = nil, cropRect: CGRect? = nil,
                pixelFormat: PixelBuffer.PixelFormat = .rgba8,
                memoryBudget: Int = 0) {
        self.targetSize = targetSize
        self.cropRect = cropRect
        self.pixelFormat = pixelFormat
        self.memoryBudget = memoryBudget
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

/// Describes the native decode capabilities of a format decoder.
public struct DecoderCapabilities: OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The decoder can produce downscaled output without fully decoding
    /// (e.g., JPEG 1/2-1/4-1/8, JXL progressive DC).
    public static let shrinkOnLoad = DecoderCapabilities(rawValue: 1 << 0)

    /// The decoder can decode a sub-region of the image without decoding
    /// the full image (e.g., JPEG crop_scanline, WebP use_cropping).
    public static let regionDecode = DecoderCapabilities(rawValue: 1 << 1)
}

// MARK: - Errors

/// Errors produced by image decoders.
public enum ImageDecoderError: Error {
    /// The input data is not a valid image of this format.
    case invalidData
    /// The decode operation failed. The associated string provides details.
    case decodeFailed(String)
    /// The requested operation is not supported by this decoder.
    case unsupportedOperation
    /// The provided decode options are invalid (e.g., crop rect out of bounds).
    case invalidOptions(String)
}

// MARK: - Protocol

/// A format-specific image decoder that reads compressed data and produces raw pixels.
///
/// Conforming types are responsible for:
/// 1. Reading image headers to populate `metadata` without a full decode.
/// 2. Decoding to a `PixelBuffer` with optional downscaling and/or region cropping.
/// 3. Using the most efficient native codec path based on the requested `DecodeOptions`.
public protocol ImageDecoder: AnyObject {
    /// Creates a decoder from a file URL. Returns `nil` if the file
    /// cannot be read or is not a valid image of this format.
    init?(url: URL)

    /// Creates a decoder from in-memory data. Returns `nil` if the
    /// data is not a valid image of this format.
    init?(data: Data)

    /// Metadata extracted from the image header. Available immediately
    /// after successful initialization without a full decode.
    var metadata: ImageMetadata { get }

    /// The native capabilities of this decoder (shrink-on-load, region decode).
    static var capabilities: DecoderCapabilities { get }

    /// Decodes the image with the given options.
    /// - Parameter options: Controls target size, crop region, and pixel format.
    /// - Returns: A pixel buffer containing the decoded image data.
    /// - Throws: `ImageDecoderError` on failure.
    func decode(options: DecodeOptions) throws -> PixelBuffer
}

extension ImageDecoder {
    /// Convenience: full-resolution decode with default options.
    public func decode() throws -> PixelBuffer {
        try decode(options: DecodeOptions())
    }

    /// Estimates the peak memory (in bytes) a full decode of this image will
    /// require, including both the output buffer and internal codec working
    /// memory. This is a conservative upper bound — actual usage may be lower.
    ///
    /// Subclasses can override via `estimatedDecodeMemoryOverride` if they
    /// have more accurate codec-specific knowledge.
    public var estimatedDecodeMemory: Int {
        let pixelCount = metadata.width * metadata.height
        // Output buffer: RGBA = 4 bytes per pixel
        let outputBytes = pixelCount * 4
        // Default: assume 2x output for internal working memory (conservative for most codecs)
        return outputBytes * 2
    }
}
