//
//  JPEGDecoder.swift
//  ImageIOKit
//
//  JPEG decoder using libjpeg (standard API).
//  Supports shrink-on-load (1/2, 1/4, 1/8) via scale_num/scale_denom
//  and region decode via jpeg_crop_scanline + jpeg_skip_scanlines.
//

import Foundation
import CoreGraphics
import libjpeg

public final class JPEGDecoder: ImageDecoder {

    public static let capabilities: DecoderCapabilities = [.shrinkOnLoad, .regionDecode]

    public let metadata: ImageMetadata

    private let imageData: Data

    /// JPEG supports these DCT scaling ratios: 1/1, 1/2, 1/4, 1/8
    private struct ScaleFactor {
        var num: UInt32
        var denom: UInt32
    }

    private static let jpegScaleFactors: [ScaleFactor] = [
        ScaleFactor(num: 1, denom: 1),
        ScaleFactor(num: 1, denom: 2),
        ScaleFactor(num: 1, denom: 4),
        ScaleFactor(num: 1, denom: 8),
    ]

    // MARK: - Init

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        self.imageData = data
        guard let meta = JPEGDecoder.readHeader(data: data) else { return nil }
        self.metadata = meta
    }

    // MARK: - Header Reading

    private static func readHeader(data: Data) -> ImageMetadata? {
        var cinfo = jpeg_decompress_struct()
        var jerr = jpeg_error_mgr()
        cinfo.err = jpeg_std_error(&jerr)
        jpeg_CreateDecompress(&cinfo, JPEG_LIB_VERSION, MemoryLayout<jpeg_decompress_struct>.size)
        defer { jpeg_destroy_decompress(&cinfo) }

        let ok: Bool = data.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return false }
            jpeg_mem_src(&cinfo, baseAddress.assumingMemoryBound(to: UInt8.self), UInt(data.count))
            return jpeg_read_header(&cinfo, 1) == JPEG_HEADER_OK
        }
        guard ok else { return nil }

        let colorModel: ImageColorModel = (cinfo.jpeg_color_space == JCS_GRAYSCALE) ? .grayscale : .rgb

        return ImageMetadata(
            width: Int(cinfo.image_width), height: Int(cinfo.image_height),
            hasAlpha: false, colorModel: colorModel
        )
    }

    // MARK: - Decode

    public func decode(options: DecodeOptions) throws -> PixelBuffer {
        if let cropRect = options.cropRect {
            return try decodeRegion(cropRect: cropRect, targetSize: options.targetSize,
                                    pixelFormat: options.pixelFormat)
        }
        return try decodeFull(targetSize: options.targetSize, pixelFormat: options.pixelFormat)
    }

    // MARK: - Full Decode (Standard libjpeg)

    private func decodeFull(targetSize: CGSize?, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        var cinfo = jpeg_decompress_struct()
        var jerr = jpeg_error_mgr()
        cinfo.err = jpeg_std_error(&jerr)
        jpeg_CreateDecompress(&cinfo, JPEG_LIB_VERSION, MemoryLayout<jpeg_decompress_struct>.size)
        defer { jpeg_destroy_decompress(&cinfo) }

        try imageData.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else {
                throw ImageDecoderError.invalidData
            }
            jpeg_mem_src(&cinfo, baseAddress.assumingMemoryBound(to: UInt8.self), UInt(imageData.count))
        }

        guard jpeg_read_header(&cinfo, 1) == JPEG_HEADER_OK else {
            throw ImageDecoderError.invalidData
        }

        // Apply shrink-on-load scale factor
        let scaleFactor = JPEGDecoder.bestScaleFactor(
            imageWidth: metadata.width, imageHeight: metadata.height, for: targetSize
        )
        cinfo.scale_num = scaleFactor.num
        cinfo.scale_denom = scaleFactor.denom

        // Always decode to RGBA for simplicity
        cinfo.out_color_space = JCS_EXT_RGBA
        jpeg_calc_output_dimensions(&cinfo)

        guard jpeg_start_decompress(&cinfo) != 0 else {
            throw ImageDecoderError.decodeFailed("jpeg_start_decompress failed")
        }

        let outWidth = Int(cinfo.output_width)
        let outHeight = Int(cinfo.output_height)
        let bpp = 4 // RGBA
        let buffer = PixelBuffer(width: outWidth, height: outHeight, pixelFormat: .rgba8)

        let scanlineBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outWidth * bpp)
        defer { scanlineBuffer.deallocate() }

        var row: UInt32 = 0
        while row < cinfo.output_height {
            var scanlinePtr: UnsafeMutablePointer<UInt8>? = scanlineBuffer
            jpeg_read_scanlines(&cinfo, &scanlinePtr, 1)
            let dstOffset = Int(row) * buffer.bytesPerRow
            memcpy(buffer.data.advanced(by: dstOffset), scanlineBuffer, outWidth * bpp)
            row += 1
        }

        jpeg_finish_decompress(&cinfo)

        // Software scale to exact target size if the DCT scale factor didn't match exactly
        if let targetSize, Int(targetSize.width) != outWidth || Int(targetSize.height) != outHeight {
            if let scaled = SoftwareScaler.scale(buffer, to: targetSize) {
                return convertPixelFormatIfNeeded(scaled, to: pixelFormat)
            }
        }

        return convertPixelFormatIfNeeded(buffer, to: pixelFormat)
    }

    // MARK: - Region Decode (Standard libjpeg)

    private func decodeRegion(cropRect: CGRect, targetSize: CGSize?,
                              pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        var cinfo = jpeg_decompress_struct()
        var jerr = jpeg_error_mgr()
        cinfo.err = jpeg_std_error(&jerr)
        jpeg_CreateDecompress(&cinfo, JPEG_LIB_VERSION, MemoryLayout<jpeg_decompress_struct>.size)
        defer { jpeg_destroy_decompress(&cinfo) }

        try imageData.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else {
                throw ImageDecoderError.invalidData
            }
            jpeg_mem_src(&cinfo, baseAddress.assumingMemoryBound(to: UInt8.self), UInt(imageData.count))
        }

        guard jpeg_read_header(&cinfo, 1) == JPEG_HEADER_OK else {
            throw ImageDecoderError.invalidData
        }

        // Apply scale factor if target size is specified
        if let targetSize {
            let scaleFactor = JPEGDecoder.bestScaleFactor(
                imageWidth: Int(cropRect.width), imageHeight: Int(cropRect.height), for: targetSize
            )
            cinfo.scale_num = scaleFactor.num
            cinfo.scale_denom = scaleFactor.denom
        }

        cinfo.out_color_space = JCS_EXT_RGBA
        jpeg_calc_output_dimensions(&cinfo)

        guard jpeg_start_decompress(&cinfo) != 0 else {
            throw ImageDecoderError.decodeFailed("jpeg_start_decompress failed")
        }

        // Calculate scaled crop coordinates
        let scaleX = CGFloat(cinfo.output_width) / CGFloat(metadata.width)
        let scaleY = CGFloat(cinfo.output_height) / CGFloat(metadata.height)

        var cropX = UInt32(max(0, (cropRect.origin.x * scaleX).rounded(.down)))
        var cropWidth = UInt32(min(CGFloat(cinfo.output_width) - CGFloat(cropX),
                                   (cropRect.width * scaleX).rounded(.up)))
        let cropY = UInt32(max(0, (cropRect.origin.y * scaleY).rounded(.down)))
        let cropHeight = UInt32(min(CGFloat(cinfo.output_height) - CGFloat(cropY),
                                    (cropRect.height * scaleY).rounded(.up)))

        // jpeg_crop_scanline aligns to MCU boundaries — it may adjust cropX and cropWidth
        jpeg_crop_scanline(&cinfo, &cropX, &cropWidth)

        let outWidth = Int(cropWidth)
        let outHeight = Int(cropHeight)
        let bpp = 4  // RGBA
        let scanlineBytesPerRow = Int(cinfo.output_width) * bpp
        let buffer = PixelBuffer(width: outWidth, height: outHeight, pixelFormat: .rgba8)

        let scanlineBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: scanlineBytesPerRow)
        defer { scanlineBuffer.deallocate() }

        // Skip rows before the crop region
        if cropY > 0 {
            jpeg_skip_scanlines(&cinfo, cropY)
        }

        // Read the crop region rows
        var rowsRead: UInt32 = 0
        while rowsRead < cropHeight {
            var scanlinePtr: UnsafeMutablePointer<UInt8>? = scanlineBuffer
            jpeg_read_scanlines(&cinfo, &scanlinePtr, 1)

            // Copy only the cropped portion of the scanline
            let srcOffset = Int(cropX) * bpp
            let dstOffset = Int(rowsRead) * buffer.bytesPerRow
            memcpy(buffer.data.advanced(by: dstOffset),
                   scanlineBuffer.advanced(by: srcOffset),
                   outWidth * bpp)
            rowsRead += 1
        }

        // Skip remaining rows and finish
        let remaining = cinfo.output_height - cropY - cropHeight
        if remaining > 0 {
            jpeg_skip_scanlines(&cinfo, remaining)
        }
        jpeg_finish_decompress(&cinfo)

        // Software scale to exact target size if needed
        if let targetSize, Int(targetSize.width) != outWidth || Int(targetSize.height) != outHeight {
            if let scaled = SoftwareScaler.scale(buffer, to: targetSize) {
                return convertPixelFormatIfNeeded(scaled, to: pixelFormat)
            }
        }

        return convertPixelFormatIfNeeded(buffer, to: pixelFormat)
    }

    // MARK: - Helpers

    /// Finds the best JPEG DCT scaling factor for the target size.
    /// Picks the smallest factor that still produces output >= targetSize.
    private static func bestScaleFactor(imageWidth: Int, imageHeight: Int, for targetSize: CGSize?) -> ScaleFactor {
        guard let targetSize else { return ScaleFactor(num: 1, denom: 1) }

        let targetWidth = Int(targetSize.width)
        let targetHeight = Int(targetSize.height)
        var best = jpegScaleFactors[0] // 1/1

        for f in jpegScaleFactors {
            let scaledW = (imageWidth * Int(f.num) + Int(f.denom) - 1) / Int(f.denom)
            let scaledH = (imageHeight * Int(f.num) + Int(f.denom) - 1) / Int(f.denom)
            if scaledW >= targetWidth && scaledH >= targetHeight {
                best = f
            }
        }
        return best
    }

    private func convertPixelFormatIfNeeded(_ source: PixelBuffer, to format: PixelBuffer.PixelFormat) -> PixelBuffer {
        guard format != .rgba8 else { return source }
        if let converted = convertPixelFormat(source, to: format) {
            return converted
        }
        return source
    }

    private func convertPixelFormat(_ source: PixelBuffer, to format: PixelBuffer.PixelFormat) -> PixelBuffer? {
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
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
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
