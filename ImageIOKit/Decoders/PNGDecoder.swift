//
//  PNGDecoder.swift
//  ImageIOKit
//
//  PNG decoder using libspng. Full decode only — no native shrink or region
//  decode. Falls back to SoftwareScaler for downscaling and cropping.
//

import Foundation
import CoreGraphics
import CLibspng

public final class PNGDecoder: ImageDecoder {

    public static let capabilities: DecoderCapabilities = []

    public let metadata: ImageMetadata

    private let imageData: Data

    // MARK: - Init

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        self.imageData = data
        guard let meta = PNGDecoder.readHeader(data: data) else { return nil }
        self.metadata = meta
    }

    // MARK: - Header Reading

    private static func readHeader(data: Data) -> ImageMetadata? {
        guard let ctx = spng_ctx_new(0) else { return nil }
        defer { spng_ctx_free(ctx) }

        let setResult = data.withUnsafeBytes { bufferPtr -> Int32 in
            guard let baseAddress = bufferPtr.baseAddress else { return -1 }
            return spng_set_png_buffer(ctx, baseAddress, data.count)
        }
        guard setResult == 0 else { return nil }

        var ihdr = spng_ihdr()
        guard spng_get_ihdr(ctx, &ihdr) == 0 else { return nil }

        let hasAlpha = ihdr.color_type == SPNG_COLOR_TYPE_TRUECOLOR_ALPHA.rawValue ||
                       ihdr.color_type == SPNG_COLOR_TYPE_GRAYSCALE_ALPHA.rawValue ||
                       ihdr.color_type == SPNG_COLOR_TYPE_INDEXED.rawValue // indexed may have tRNS

        let colorModel: ImageColorModel = (ihdr.color_type == SPNG_COLOR_TYPE_GRAYSCALE.rawValue ||
                                            ihdr.color_type == SPNG_COLOR_TYPE_GRAYSCALE_ALPHA.rawValue)
                                            ? .grayscale : .rgb

        return ImageMetadata(
            width: Int(ihdr.width),
            height: Int(ihdr.height),
            hasAlpha: hasAlpha,
            colorModel: colorModel
        )
    }

    // MARK: - Decode

    public func decode(options: DecodeOptions) throws -> PixelBuffer {
        guard let ctx = spng_ctx_new(0) else {
            throw ImageDecoderError.decodeFailed("Failed to create spng context")
        }
        defer { spng_ctx_free(ctx) }

        let setResult = imageData.withUnsafeBytes { bufferPtr -> Int32 in
            guard let baseAddress = bufferPtr.baseAddress else { return -1 }
            return spng_set_png_buffer(ctx, baseAddress, imageData.count)
        }
        guard setResult == 0 else {
            throw ImageDecoderError.invalidData
        }

        // Decode as RGBA8
        let fmt = Int32(SPNG_FMT_RGBA8.rawValue)
        var outSize: Int = 0
        guard spng_decoded_image_size(ctx, fmt, &outSize) == 0 else {
            throw ImageDecoderError.decodeFailed("spng_decoded_image_size failed")
        }

        let buffer = PixelBuffer(width: metadata.width, height: metadata.height, pixelFormat: .rgba8)
        let decodeResult = spng_decode_image(ctx, buffer.data, outSize, fmt, 0)
        guard decodeResult == 0 else {
            throw ImageDecoderError.decodeFailed("spng_decode_image failed with error \(decodeResult)")
        }

        // Apply software crop and/or scale as needed
        return try applyOptions(buffer, options: options)
    }

    // MARK: - Post-Processing

    private func applyOptions(_ buffer: PixelBuffer, options: DecodeOptions) throws -> PixelBuffer {
        var result = buffer

        // Crop first (reduces data before scaling)
        if let cropRect = options.cropRect {
            guard let cropped = SoftwareScaler.crop(result, to: cropRect) else {
                throw ImageDecoderError.invalidOptions("Crop rect \(cropRect) is out of bounds")
            }
            result = cropped
        }

        // Then scale
        if let targetSize = options.targetSize {
            let fitSize = SoftwareScaler.fittingSize(
                for: CGSize(width: result.width, height: result.height),
                in: targetSize
            )
            if let scaled = SoftwareScaler.scale(result, to: fitSize) {
                result = scaled
            }
        }

        return result
    }
}
