//
//  PNGEncoder.swift
//  ImageIOKit
//
//  PNG encoder using libspng.
//  Always lossless. Speed option maps to zlib compression level.
//

import Foundation
import CLibspng

public final class PNGEncoder: ImageEncoder {

    public static let format: ImageFileFormat = .png
    public static let supportsAlpha = true
    public static let supportsLossless = true

    public init() {}

    public func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data {
        guard let ctx = spng_ctx_new(Int32(SPNG_CTX_ENCODER.rawValue)) else {
            throw ImageEncoderError.encodeFailed("Failed to create spng encoder context")
        }
        defer { spng_ctx_free(ctx) }

        // Configure to encode to buffer
        spng_set_option(ctx, SPNG_ENCODE_TO_BUFFER, 1)

        // Map speed 0–10 → compression level 9–0 (inverted: speed 0 = best compression = level 9)
        let compressionLevel = 9 - min(9, options.speed * 9 / 10)
        spng_set_option(ctx, SPNG_IMG_COMPRESSION_LEVEL, Int32(compressionLevel))

        // Set up IHDR based on pixel format
        var ihdr = spng_ihdr()
        ihdr.width = UInt32(buffer.width)
        ihdr.height = UInt32(buffer.height)
        ihdr.bit_depth = 8

        let spngFormat: Int32
        switch buffer.pixelFormat {
        case .rgba8:
            ihdr.color_type = UInt8(SPNG_COLOR_TYPE_TRUECOLOR_ALPHA.rawValue)
            spngFormat = Int32(SPNG_FMT_PNG.rawValue)
        case .rgb8:
            ihdr.color_type = UInt8(SPNG_COLOR_TYPE_TRUECOLOR.rawValue)
            spngFormat = Int32(SPNG_FMT_PNG.rawValue)
        case .gray8:
            ihdr.color_type = UInt8(SPNG_COLOR_TYPE_GRAYSCALE.rawValue)
            spngFormat = Int32(SPNG_FMT_PNG.rawValue)
        case .grayAlpha8:
            ihdr.color_type = UInt8(SPNG_COLOR_TYPE_GRAYSCALE_ALPHA.rawValue)
            spngFormat = Int32(SPNG_FMT_PNG.rawValue)
        }

        guard spng_set_ihdr(ctx, &ihdr) == 0 else {
            throw ImageEncoderError.encodeFailed("spng_set_ihdr failed")
        }

        // Encode the image
        let imageSize = buffer.bytesPerRow * buffer.height
        let encodeResult = spng_encode_image(
            ctx, buffer.data, imageSize,
            spngFormat, Int32(SPNG_ENCODE_FINALIZE.rawValue)
        )
        guard encodeResult == 0 else {
            throw ImageEncoderError.encodeFailed("spng_encode_image failed with error \(encodeResult)")
        }

        // Retrieve the encoded PNG buffer
        var pngLen: Int = 0
        var error: Int32 = 0
        guard let pngBuf = spng_get_png_buffer(ctx, &pngLen, &error), error == 0 else {
            throw ImageEncoderError.encodeFailed("spng_get_png_buffer failed with error \(error)")
        }

        let data = Data(bytes: pngBuf, count: pngLen)
        free(pngBuf)
        return data
    }
}
