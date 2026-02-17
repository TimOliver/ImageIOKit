//
//  WebPEncoder.swift
//  ImageIOKit
//
//  WebP encoder using libwebp's simple API.
//  Supports both lossy (WebPEncodeRGBA) and lossless (WebPEncodeLosslessRGBA).
//

import Foundation
import CoreGraphics
import libwebp

public final class WebPEncoder: ImageEncoder {

    public static let format: ImageFileFormat = .webp
    public static let supportsAlpha = true
    public static let supportsLossless = true

    public init() {}

    public func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data {
        // WebP requires RGBA or RGB input. Convert grayscale formats to RGB/RGBA.
        let sourceBuffer: PixelBuffer
        let useRGBA: Bool

        switch buffer.pixelFormat {
        case .rgba8:
            sourceBuffer = buffer
            useRGBA = true
        case .rgb8:
            sourceBuffer = buffer
            useRGBA = false
        case .gray8:
            guard let converted = convertToRGB(buffer) else {
                throw ImageEncoderError.unsupportedPixelFormat
            }
            sourceBuffer = converted
            useRGBA = false
        case .grayAlpha8:
            guard let converted = convertToRGBA(buffer) else {
                throw ImageEncoderError.unsupportedPixelFormat
            }
            sourceBuffer = converted
            useRGBA = true
        }

        let width = Int32(sourceBuffer.width)
        let height = Int32(sourceBuffer.height)
        let stride = Int32(sourceBuffer.bytesPerRow)
        let pixels = sourceBuffer.data.assumingMemoryBound(to: UInt8.self)

        var output: UnsafeMutablePointer<UInt8>? = nil
        let outputSize: Int

        if options.lossless {
            if useRGBA {
                outputSize = WebPEncodeLosslessRGBA(pixels, width, height, stride, &output)
            } else {
                outputSize = WebPEncodeLosslessRGB(pixels, width, height, stride, &output)
            }
        } else {
            let quality = Float(options.quality * 100.0)
            if useRGBA {
                outputSize = WebPEncodeRGBA(pixels, width, height, stride, quality, &output)
            } else {
                outputSize = WebPEncodeRGB(pixels, width, height, stride, quality, &output)
            }
        }

        guard outputSize > 0, let output else {
            throw ImageEncoderError.encodeFailed("WebP encode failed")
        }

        let data = Data(bytes: output, count: outputSize)
        WebPFree(output)
        return data
    }

    // MARK: - Helpers

    private func convertToRGB(_ buffer: PixelBuffer) -> PixelBuffer? {
        guard let cgImage = buffer.makeCGImage() else { return nil }
        let dest = PixelBuffer(width: buffer.width, height: buffer.height, pixelFormat: .rgb8)
        guard let ctx = CGContext(
            data: dest.data, width: dest.width, height: dest.height,
            bitsPerComponent: 8, bytesPerRow: dest.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        return dest
    }

    private func convertToRGBA(_ buffer: PixelBuffer) -> PixelBuffer? {
        guard let cgImage = buffer.makeCGImage() else { return nil }
        let dest = PixelBuffer(width: buffer.width, height: buffer.height, pixelFormat: .rgba8)
        guard let ctx = CGContext(
            data: dest.data, width: dest.width, height: dest.height,
            bitsPerComponent: 8, bytesPerRow: dest.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        return dest
    }
}
