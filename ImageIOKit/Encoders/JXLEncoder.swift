//
//  JXLEncoder.swift
//  ImageIOKit
//
//  JPEG XL encoder using libjxl.
//  Supports both lossy and lossless encoding.
//  Quality maps to distance: 1.0 at q=1.0, 15.0 at q=0.0. Lossless = distance 0.
//

import Foundation
import libjxl

public final class JXLEncoder: ImageEncoder {

    public static let format: ImageFileFormat = .jpegXL
    public static let supportsAlpha = true
    public static let supportsLossless = true

    public init() {}

    public func encode(_ buffer: PixelBuffer, options: EncodeOptions) throws -> Data {
        guard let enc = JxlEncoderCreate(nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create JXL encoder")
        }
        defer { JxlEncoderDestroy(enc) }

        // Set up basic info
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(buffer.width)
        info.ysize = UInt32(buffer.height)
        info.bits_per_sample = 8
        info.exponent_bits_per_sample = 0
        info.uses_original_profile = options.lossless ? 1 : 0

        let numChannels: UInt32
        switch buffer.pixelFormat {
        case .rgba8:
            numChannels = 4
            info.num_color_channels = 3
            info.num_extra_channels = 1
            info.alpha_bits = 8
            info.alpha_exponent_bits = 0
        case .rgb8:
            numChannels = 3
            info.num_color_channels = 3
            info.num_extra_channels = 0
            info.alpha_bits = 0
        case .gray8:
            numChannels = 1
            info.num_color_channels = 1
            info.num_extra_channels = 0
            info.alpha_bits = 0
        case .grayAlpha8:
            numChannels = 2
            info.num_color_channels = 1
            info.num_extra_channels = 1
            info.alpha_bits = 8
            info.alpha_exponent_bits = 0
        }

        guard JxlEncoderSetBasicInfo(enc, &info) == JXL_ENC_SUCCESS else {
            throw ImageEncoderError.encodeFailed("JxlEncoderSetBasicInfo failed")
        }

        // Set color encoding
        var color = JxlColorEncoding()
        if info.num_color_channels == 1 {
            JxlColorEncodingSetToLinearSRGB(&color, 1) // grayscale
        } else {
            JxlColorEncodingSetToSRGB(&color, 0)
        }
        guard JxlEncoderSetColorEncoding(enc, &color) == JXL_ENC_SUCCESS else {
            throw ImageEncoderError.encodeFailed("JxlEncoderSetColorEncoding failed")
        }

        // Configure encoder options
        let frameSettings = JxlEncoderFrameSettingsCreate(enc, nil)

        if options.lossless {
            JxlEncoderSetFrameLossless(frameSettings, 1)
            JxlEncoderSetFrameDistance(frameSettings, 0)
        } else {
            // Map quality 0.0–1.0 → distance 15.0–1.0 (lower distance = better quality)
            let distance = Float(1.0 + (1.0 - options.quality) * 14.0)
            JxlEncoderSetFrameDistance(frameSettings, distance)
        }

        // Map speed 0–10 → JXL effort 10–1 (inverted: our speed 0 = slowest = effort 10)
        let effort = Int32(10 - min(9, options.speed))
        JxlEncoderFrameSettingsSetOption(frameSettings, JXL_ENC_FRAME_SETTING_EFFORT, Int64(effort))

        // Set up pixel format
        var pixelFormat = JxlPixelFormat(
            num_channels: numChannels,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        // Add the image frame
        let imageSize = buffer.bytesPerRow * buffer.height
        guard JxlEncoderAddImageFrame(frameSettings, &pixelFormat, buffer.data, imageSize) == JXL_ENC_SUCCESS else {
            throw ImageEncoderError.encodeFailed("JxlEncoderAddImageFrame failed")
        }

        // Signal no more input
        JxlEncoderCloseInput(enc)

        // Process output
        var outputData = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var status: JxlEncoderStatus

        repeat {
            var availOut = chunk.count
            var nextOut: UnsafeMutablePointer<UInt8>? = nil
            chunk.withUnsafeMutableBufferPointer { bufferPtr in
                nextOut = bufferPtr.baseAddress
            }
            status = JxlEncoderProcessOutput(enc, &nextOut, &availOut)

            let bytesWritten = chunk.count - availOut
            if bytesWritten > 0 {
                outputData.append(contentsOf: chunk.prefix(bytesWritten))
            }
        } while status == JXL_ENC_NEED_MORE_OUTPUT

        guard status == JXL_ENC_SUCCESS else {
            throw ImageEncoderError.encodeFailed("JxlEncoderProcessOutput failed with status \(status.rawValue)")
        }

        return outputData
    }
}
