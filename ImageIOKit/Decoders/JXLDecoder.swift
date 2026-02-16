//
//  JXLDecoder.swift
//  ImageIOKit
//
//  JPEG XL decoder using libjxl.
//  Supports progressive DC preview (1:8 shrink) for thumbnails.
//  Full decode for all other requests, with SoftwareScaler fallback.
//

import Foundation
import CoreGraphics
import libjxl

public final class JXLDecoder: ImageDecoder {

    public static let capabilities: DecoderCapabilities = [.shrinkOnLoad]

    public let metadata: ImageMetadata

    private let imageData: Data

    /// libjxl decodes into float32 internally and keeps the full image in memory
    /// during the VarDCT inverse transform. Peak memory is roughly 8× the raw
    /// output pixel count. This is inherent to libjxl's architecture and cannot
    /// be reduced from the API side.
    private static let internalMemoryMultiplier = 8

    /// Estimated peak memory for a full-resolution decode of this image.
    public var estimatedDecodeMemory: Int {
        metadata.width * metadata.height * 4 * JXLDecoder.internalMemoryMultiplier
    }

    // MARK: - Init

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        self.imageData = data
        guard let meta = JXLDecoder.readHeader(data: data) else { return nil }
        self.metadata = meta
    }

    // MARK: - Header Reading

    private static func readHeader(data: Data) -> ImageMetadata? {
        guard let dec = JxlDecoderCreate(nil) else { return nil }
        defer { JxlDecoderDestroy(dec) }

        var status = JxlDecoderSubscribeEvents(dec, Int32(JXL_DEC_BASIC_INFO.rawValue))
        guard status == JXL_DEC_SUCCESS else { return nil }

        let inputResult = data.withUnsafeBytes { bufferPtr -> JxlDecoderStatus in
            guard let baseAddress = bufferPtr.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, baseAddress.assumingMemoryBound(to: UInt8.self), data.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else { return nil }
        JxlDecoderCloseInput(dec)

        status = JxlDecoderProcessInput(dec)
        guard status == JXL_DEC_BASIC_INFO else { return nil }

        var info = JxlBasicInfo()
        guard JxlDecoderGetBasicInfo(dec, &info) == JXL_DEC_SUCCESS else { return nil }

        let hasAlpha = info.alpha_bits > 0
        let colorModel: ImageColorModel = info.num_color_channels == 1 ? .grayscale : .rgb

        return ImageMetadata(
            width: Int(info.xsize),
            height: Int(info.ysize),
            hasAlpha: hasAlpha,
            colorModel: colorModel
        )
    }

    // MARK: - Decode

    public func decode(options: DecodeOptions) throws -> PixelBuffer {
        let dcWidth = metadata.width / 8
        let dcHeight = metadata.height / 8
        let dcAvailable = dcWidth > 0 && dcHeight > 0

        // Determine if we should use DC preview instead of a full decode.
        // Two reasons to prefer DC:
        //   1. The target size fits within the DC dimensions (quality-lossless path)
        //   2. A full decode would exceed the memory budget (quality-tradeoff path)
        var useDCFallback = false

        if let targetSize = options.targetSize, options.cropRect == nil, dcAvailable {
            if Int(targetSize.width) <= dcWidth && Int(targetSize.height) <= dcHeight {
                // Target fits within DC — no quality loss
                useDCFallback = true
            } else if options.memoryBudget > 0 && estimatedDecodeMemory > options.memoryBudget {
                // Full decode would exceed memory budget — accept quality tradeoff
                useDCFallback = true
            }
        }

        if useDCFallback {
            if let dcBuffer = try? decodeDCPreview(pixelFormat: options.pixelFormat) {
                let targetSize = options.targetSize!
                if Int(targetSize.width) != dcBuffer.width || Int(targetSize.height) != dcBuffer.height {
                    let fitSize = SoftwareScaler.fittingSize(
                        for: CGSize(width: dcBuffer.width, height: dcBuffer.height),
                        in: targetSize
                    )
                    if let scaled = SoftwareScaler.scale(dcBuffer, to: fitSize) {
                        return scaled
                    }
                }
                return dcBuffer
            }
            // DC decode failed — fall through to full decode
        }

        // Check memory budget before committing to a full decode
        if options.memoryBudget > 0 && estimatedDecodeMemory > options.memoryBudget {
            throw ImageDecoderError.decodeFailed(
                "JXL full decode would require ~\(estimatedDecodeMemory / 1_000_000) MB, " +
                "exceeding the \(options.memoryBudget / 1_000_000) MB memory budget"
            )
        }

        // Full decode
        var buffer = try decodeFull(pixelFormat: options.pixelFormat)

        // Apply software crop and/or scale
        if let cropRect = options.cropRect {
            guard let cropped = SoftwareScaler.crop(buffer, to: cropRect) else {
                throw ImageDecoderError.invalidOptions("Crop rect \(cropRect) is out of bounds")
            }
            buffer = cropped
        }

        if let targetSize = options.targetSize {
            let fitSize = SoftwareScaler.fittingSize(
                for: CGSize(width: buffer.width, height: buffer.height),
                in: targetSize
            )
            if let scaled = SoftwareScaler.scale(buffer, to: fitSize) {
                buffer = scaled
            }
        }

        return buffer
    }

    // MARK: - Full Decode

    private func decodeFull(pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        guard let dec = JxlDecoderCreate(nil) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL decoder")
        }
        defer { JxlDecoderDestroy(dec) }

        let events = Int32(JXL_DEC_FULL_IMAGE.rawValue | JXL_DEC_COLOR_ENCODING.rawValue)
        guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("JxlDecoderSubscribeEvents failed")
        }

        let inputResult = imageData.withUnsafeBytes { bufferPtr -> JxlDecoderStatus in
            guard let baseAddress = bufferPtr.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, baseAddress.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.invalidData
        }
        JxlDecoderCloseInput(dec)

        var format = JxlPixelFormat(
            num_channels: pixelFormat == .gray8 ? 1 : 4,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        var buffer: PixelBuffer?

        var status = JxlDecoderProcessInput(dec)
        while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
            switch status {
            case JXL_DEC_COLOR_ENCODING:
                break

            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                var outSize: Int = 0
                guard JxlDecoderImageOutBufferSize(dec, &format, &outSize) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("JxlDecoderImageOutBufferSize failed")
                }

                let outFormat: PixelBuffer.PixelFormat = pixelFormat == .gray8 ? .gray8 : .rgba8
                let pixBuf = PixelBuffer(width: metadata.width, height: metadata.height, pixelFormat: outFormat)

                guard JxlDecoderSetImageOutBuffer(dec, &format, pixBuf.data, outSize) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("JxlDecoderSetImageOutBuffer failed")
                }
                buffer = pixBuf

            case JXL_DEC_FULL_IMAGE:
                break

            default:
                break
            }
            status = JxlDecoderProcessInput(dec)
        }

        guard status != JXL_DEC_ERROR, let result = buffer else {
            throw ImageDecoderError.decodeFailed("JXL decode failed")
        }

        return result
    }

    // MARK: - DC Preview (1:8)

    private func decodeDCPreview(pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        guard let dec = JxlDecoderCreate(nil) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL decoder for DC preview")
        }
        defer { JxlDecoderDestroy(dec) }

        let events = Int32(JXL_DEC_FULL_IMAGE.rawValue)
        guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("JxlDecoderSubscribeEvents failed")
        }

        // Request progressive DC-only decode
        JxlDecoderSetProgressiveDetail(dec, kDC)

        let inputResult = imageData.withUnsafeBytes { bufferPtr -> JxlDecoderStatus in
            guard let baseAddress = bufferPtr.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, baseAddress.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.invalidData
        }
        JxlDecoderCloseInput(dec)

        let dcWidth = max(1, metadata.width / 8)
        let dcHeight = max(1, metadata.height / 8)

        var format = JxlPixelFormat(
            num_channels: pixelFormat == .gray8 ? 1 : 4,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        var buffer: PixelBuffer?
        var status = JxlDecoderProcessInput(dec)

        while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
            switch status {
            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                var outSize: Int = 0
                guard JxlDecoderImageOutBufferSize(dec, &format, &outSize) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("DC preview: JxlDecoderImageOutBufferSize failed")
                }

                let outFormat: PixelBuffer.PixelFormat = pixelFormat == .gray8 ? .gray8 : .rgba8
                let pixBuf = PixelBuffer(width: dcWidth, height: dcHeight, pixelFormat: outFormat)
                guard JxlDecoderSetImageOutBuffer(dec, &format, pixBuf.data, outSize) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("DC preview: JxlDecoderSetImageOutBuffer failed")
                }
                buffer = pixBuf

            case JXL_DEC_FULL_IMAGE:
                break

            default:
                break
            }
            status = JxlDecoderProcessInput(dec)
        }

        guard let result = buffer else {
            throw ImageDecoderError.decodeFailed("JXL DC preview decode failed")
        }

        return result
    }
}
