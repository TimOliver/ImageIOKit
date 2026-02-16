//
//  WebPDecoder.swift
//  ImageIOKit
//
//  WebP decoder using libwebp's advanced API.
//  Supports native crop (use_cropping) and scale (use_scaling) — crop is
//  applied first by the decoder, then scale, so peak memory = output size.
//

import Foundation
import CoreGraphics
import libwebp

public final class WebPDecoder: ImageDecoder {

    public static let capabilities: DecoderCapabilities = [.shrinkOnLoad, .regionDecode]

    public let metadata: ImageMetadata

    private let imageData: Data

    // MARK: - Init

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        self.imageData = data
        guard let meta = WebPDecoder.readHeader(data: data) else { return nil }
        self.metadata = meta
    }

    // MARK: - Header Reading

    private static func readHeader(data: Data) -> ImageMetadata? {
        var features = WebPBitstreamFeatures()

        let status = data.withUnsafeBytes { bufferPtr -> VP8StatusCode in
            guard let baseAddress = bufferPtr.baseAddress else { return VP8_STATUS_BITSTREAM_ERROR }
            return WebPGetFeatures(baseAddress.assumingMemoryBound(to: UInt8.self),
                                   data.count, &features)
        }
        guard status == VP8_STATUS_OK else { return nil }

        return ImageMetadata(
            width: Int(features.width),
            height: Int(features.height),
            hasAlpha: features.has_alpha != 0,
            colorModel: .rgb
        )
    }

    // MARK: - Decode

    public func decode(options: DecodeOptions) throws -> PixelBuffer {
        var config = WebPDecoderConfig()
        guard WebPInitDecoderConfig(&config) != 0 else {
            throw ImageDecoderError.decodeFailed("WebPInitDecoderConfig failed")
        }

        // Set up cropping if requested
        if let cropRect = options.cropRect {
            config.options.use_cropping = 1
            config.options.crop_left = Int32(cropRect.origin.x)
            config.options.crop_top = Int32(cropRect.origin.y)
            config.options.crop_width = Int32(cropRect.width)
            config.options.crop_height = Int32(cropRect.height)
        }

        // Set up scaling if requested
        if let targetSize = options.targetSize {
            let sourceSize: CGSize
            if let cropRect = options.cropRect {
                sourceSize = cropRect.size
            } else {
                sourceSize = CGSize(width: metadata.width, height: metadata.height)
            }
            let fitSize = SoftwareScaler.fittingSize(for: sourceSize, in: targetSize)
            config.options.use_scaling = 1
            config.options.scaled_width = Int32(fitSize.width)
            config.options.scaled_height = Int32(fitSize.height)
        }

        // Request RGBA output
        config.output.colorspace = MODE_RGBA

        let status = imageData.withUnsafeBytes { bufferPtr -> VP8StatusCode in
            guard let baseAddress = bufferPtr.baseAddress else { return VP8_STATUS_BITSTREAM_ERROR }
            return WebPDecode(baseAddress.assumingMemoryBound(to: UInt8.self),
                              imageData.count, &config)
        }

        guard status == VP8_STATUS_OK else {
            WebPFreeDecBuffer(&config.output)
            throw ImageDecoderError.decodeFailed("WebPDecode failed with status \(status.rawValue)")
        }

        let rgba = config.output.u.RGBA
        let width = Int(rgba.size) > 0 ? Int(config.output.width) : metadata.width
        let height = Int(config.output.height)
        let stride = Int(rgba.stride)

        // Copy decoded data into our own buffer so we can free the WebP buffer
        let outWidth: Int
        let outHeight: Int
        if config.options.use_scaling != 0 {
            outWidth = Int(config.options.scaled_width)
            outHeight = Int(config.options.scaled_height)
        } else if config.options.use_cropping != 0 {
            outWidth = Int(config.options.crop_width)
            outHeight = Int(config.options.crop_height)
        } else {
            outWidth = metadata.width
            outHeight = metadata.height
        }

        let buffer = PixelBuffer(width: outWidth, height: outHeight, pixelFormat: .rgba8)

        // Copy row by row in case stride differs
        for row in 0..<outHeight {
            let srcOffset = row * stride
            let dstOffset = row * buffer.bytesPerRow
            let rowBytes = min(buffer.bytesPerRow, stride)
            guard let srcData = rgba.rgba else { break }
            memcpy(buffer.data.advanced(by: dstOffset),
                   srcData.advanced(by: srcOffset),
                   rowBytes)
        }

        WebPFreeDecBuffer(&config.output)

        // Convert pixel format if needed
        if options.pixelFormat != .rgba8 {
            if let converted = convertToFormat(buffer, format: options.pixelFormat) {
                return converted
            }
        }

        return buffer
    }

    // MARK: - Helpers

    private func convertToFormat(_ source: PixelBuffer, format: PixelBuffer.PixelFormat) -> PixelBuffer? {
        guard format != source.pixelFormat else { return source }
        guard let cgImage = source.makeCGImage() else { return nil }

        let dest = PixelBuffer(width: source.width, height: source.height, pixelFormat: format)
        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo

        switch format {
        case .gray8:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case .grayAlpha8:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        case .rgb8:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        case .rgba8:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        guard let ctx = CGContext(
            data: dest.data,
            width: dest.width,
            height: dest.height,
            bitsPerComponent: 8,
            bytesPerRow: dest.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        return dest
    }
}
