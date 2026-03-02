//
//  JPEGRegionDecoder.swift
//  ImageIOKit
//
//  JPEG region decoder using libjpeg (standard API).
//  Supports region decode via jpeg_crop_scanline + jpeg_skip_scanlines,
//  combined with DCT shrink-on-load (1/2, 1/4, 1/8).
//

import Foundation
import CoreGraphics
import jpeglib

struct JPEGRegionDecoder {

    private let imageData: Data
    private let imageWidth: Int
    private let imageHeight: Int

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

    /// Creates a region decoder from in-memory JPEG data.
    /// - Parameter data: The compressed JPEG data.
    /// - Returns: `nil` if the JPEG header cannot be read.
    init?(data: Data) {
        self.imageData = data
        guard let (w, h) = JPEGRegionDecoder.readDimensions(data: data) else { return nil }
        self.imageWidth = w
        self.imageHeight = h
    }

    /// Creates a region decoder from a JPEG file on disk.
    /// - Parameter url: A local file URL to a JPEG file.
    /// - Returns: `nil` if the file cannot be read or the JPEG header is invalid.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    // MARK: - Header Reading

    private static func readDimensions(data: Data) -> (Int, Int)? {
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

        return (Int(cinfo.image_width), Int(cinfo.image_height))
    }

    // MARK: - Region Decode

    /// Decodes a specific region of the JPEG image.
    /// - Parameters:
    ///   - cropRect: The region to decode, in pixel coordinates of the full image.
    ///   - targetSize: Optional target size for the decoded region (enables DCT shrink-on-load).
    ///   - pixelFormat: The desired pixel format for the output.
    /// - Returns: A pixel buffer containing the decoded region.
    func decodeRegion(cropRect: CGRect, targetSize: CGSize? = nil,
                             pixelFormat: PixelBuffer.PixelFormat = .rgba8) throws -> PixelBuffer {
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
            let scaleFactor = JPEGRegionDecoder.bestScaleFactor(
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
        let scaleX = CGFloat(cinfo.output_width) / CGFloat(imageWidth)
        let scaleY = CGFloat(cinfo.output_height) / CGFloat(imageHeight)

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

        return buffer
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
}
