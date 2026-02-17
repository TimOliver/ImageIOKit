//
//  ImageDestination.swift
//  ImageIOKit
//
//  Facade over format-specific encoders. Provides a simple API for encoding
//  a PixelBuffer to any supported format, writing to disk, and transcoding.
//

import Foundation

public final class ImageDestination {

    /// Encode a PixelBuffer to the specified format.
    /// - Parameters:
    ///   - buffer: The pixel data to encode.
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality, lossless, speed).
    /// - Returns: The encoded image data.
    public static func encode(_ buffer: PixelBuffer, format: ImageFileFormat,
                              options: EncodeOptions = EncodeOptions()) throws -> Data {
        guard let encoder = EncoderFactory.encoder(for: format) else {
            throw ImageEncoderError.encodeFailed("No encoder available for format: \(format)")
        }
        return try encoder.encode(buffer, options: options)
    }

    /// Encode and write to disk.
    /// - Parameters:
    ///   - buffer: The pixel data to encode.
    ///   - url: The file URL to write to.
    ///   - format: The target image file format.
    ///   - options: Encoding options (quality, lossless, speed).
    public static func write(_ buffer: PixelBuffer, to url: URL, format: ImageFileFormat,
                             options: EncodeOptions = EncodeOptions()) throws {
        let data = try encode(buffer, format: format, options: options)
        try data.write(to: url)
    }

    /// Decode from an image source and re-encode to a target format (convenience transcode).
    /// - Parameters:
    ///   - source: The image source to decode from.
    ///   - format: The target image file format.
    ///   - decodeOptions: Options for decoding the source image.
    ///   - encodeOptions: Options for encoding to the target format.
    /// - Returns: The transcoded image data.
    public static func transcode(from source: ImageSource, to format: ImageFileFormat,
                                 decodeOptions: DecodeOptions = DecodeOptions(),
                                 encodeOptions: EncodeOptions = EncodeOptions()) throws -> Data {
        let buffer = try source.decode(options: decodeOptions)
        return try encode(buffer, format: format, options: encodeOptions)
    }
}
