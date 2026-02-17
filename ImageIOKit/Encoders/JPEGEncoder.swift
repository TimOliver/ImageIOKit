//
//  JPEGEncoder.swift
//  ImageIOKit
//
//  JPEG encoder using libjpeg.
//  Encodes PixelBuffer → JPEG Data via jpeg_compress_struct + jpeg_mem_dest.
//  Strips alpha (JPEG has no alpha support).
//

import Foundation
import libjpeg

public final class JPEGEncoder: ImageEncoder {

    public static let format: ImageFileFormat = .jpeg
    public static let supportsAlpha = false
    public static let supportsLossless = false

    public init() {}

    public func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data {
        var cinfo = jpeg_compress_struct()
        var jerr = jpeg_error_mgr()
        cinfo.err = jpeg_std_error(&jerr)
        jpeg_CreateCompress(&cinfo, JPEG_LIB_VERSION, MemoryLayout<jpeg_compress_struct>.size)
        defer { jpeg_destroy_compress(&cinfo) }

        // Set up memory destination
        var outBuffer: UnsafeMutablePointer<UInt8>? = nil
        var outSize: UInt = 0
        jpeg_mem_dest(&cinfo, &outBuffer, &outSize)

        cinfo.image_width = JDIMENSION(buffer.width)
        cinfo.image_height = JDIMENSION(buffer.height)

        // Configure input color space based on pixel format
        switch buffer.pixelFormat {
        case .rgba8:
            cinfo.input_components = 4
            cinfo.in_color_space = JCS_EXT_RGBA
        case .rgb8:
            cinfo.input_components = 3
            cinfo.in_color_space = JCS_RGB
        case .gray8:
            cinfo.input_components = 1
            cinfo.in_color_space = JCS_GRAYSCALE
        case .grayAlpha8:
            // libjpeg doesn't support gray+alpha natively; convert to grayscale
            cinfo.input_components = 1
            cinfo.in_color_space = JCS_GRAYSCALE
        }

        jpeg_set_defaults(&cinfo)

        // Map quality 0.0–1.0 → libjpeg 0–100
        let jpegQuality = Int32(options.quality * 100.0)
        jpeg_set_quality(&cinfo, jpegQuality, 1)

        jpeg_start_compress(&cinfo, 1)

        let srcBpp = buffer.pixelFormat.bytesPerPixel
        let width = buffer.width

        if buffer.pixelFormat == .grayAlpha8 {
            // Strip alpha: copy only the gray channel per row
            let rowBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width)
            defer { rowBuffer.deallocate() }

            var row: JDIMENSION = 0
            while row < cinfo.image_height {
                let srcRow = buffer.data.advanced(by: Int(row) * buffer.bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    rowBuffer[x] = srcRow[x * 2] // gray channel only
                }
                var rowPtr: UnsafeMutablePointer<UInt8>? = rowBuffer
                jpeg_write_scanlines(&cinfo, &rowPtr, 1)
                row += 1
            }
        } else {
            // Direct scanline write for rgba8, rgb8, gray8
            let scanlineBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * srcBpp)
            defer { scanlineBuffer.deallocate() }

            var row: JDIMENSION = 0
            while row < cinfo.image_height {
                let srcOffset = Int(row) * buffer.bytesPerRow
                memcpy(scanlineBuffer, buffer.data.advanced(by: srcOffset), width * srcBpp)
                var rowPtr: UnsafeMutablePointer<UInt8>? = scanlineBuffer
                jpeg_write_scanlines(&cinfo, &rowPtr, 1)
                row += 1
            }
        }

        jpeg_finish_compress(&cinfo)

        guard let outBuffer else {
            throw ImageEncoderError.encodeFailed("jpeg_mem_dest produced no output")
        }

        let data = Data(bytes: outBuffer, count: Int(outSize))
        free(outBuffer)
        return data
    }
}
