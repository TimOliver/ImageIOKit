//
//  ImageIOKitTestsCommon.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import jxl

/// A class for managing accessing the photos of Apple Park
/// used in testing and benchmarking this framework.
public final class ImageSampleData {

    /// The formats where a valid test image is available.
    public enum Format: String, CaseIterable {
        case jpeg = "jpeg"
        case png = "png"
        case webp = "webp"
        case heic = "heic"
        case avif = "avif"
        case jpegXL = "jxl"
    }

    // Fetch the absolute URL of the image data for the desired format.
    static func urlForTestImage(with format: Format) -> URL {
        let bundleURL = resourceURL
        switch format {
        case .jpegXL:
            // Default JXL sample is the JPEG-derived variant (supports reconstruction)
            return bundleURL.appendingPathComponent("ApplePark-JPG.jxl")
        default:
            return bundleURL.appendingPathComponent("ApplePark.\(format.rawValue)")
        }
    }

    /// URL for the JXL sample that was created from a non-JPEG source (PNG).
    /// This variant does NOT support JPEG reconstruction.
    static func urlForPNGDerivedJXL() -> URL {
        resourceURL.appendingPathComponent("ApplePark-PNG.jxl")
    }

    static func urlForWebPFixture(_ name: String) -> URL {
        resourceURL.appendingPathComponent("WebP/\(name).webp")
    }

    private static var resourceURL: URL {
#if SWIFT_PACKAGE
        return Bundle.module.resourceURL!.appendingPathComponent("SampleImages")
#else
        guard let bundleURL = Bundle(for: Self.self).resourceURL else {
            fatalError("Unable to find main bundle")
        }
        return bundleURL
#endif
    }
}

/// Small deterministic fixtures that exercise metadata and transparency, not just photographs.
enum SyntheticImage {
    /// Retains a valid profile's colour transform while replacing only its display name.
    static func namedICC(_ profile: Data, name: String) -> Data {
        var output = Array(profile)
        func word(_ offset: Int) -> Int {
            output[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        func bytes(_ value: Int) -> [UInt8] {
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        }
        let count = word(128)
        let record = (0..<count).map { 132 + $0 * 12 }.first { word($0) == 0x64657363 }!
        let text = Array(name.data(using: .utf16BigEndian)!)
        let tag = Array("mluc".utf8) + [0, 0, 0, 0] + bytes(1) + bytes(12)
            + Array("enUS".utf8) + bytes(text.count) + bytes(28) + text
        while output.count % 4 != 0 { output.append(0) }
        let offset = output.count
        output += tag
        while output.count % 4 != 0 { output.append(0) }
        output.replaceSubrange(record + 4..<record + 8, with: bytes(offset))
        output.replaceSubrange(record + 8..<record + 12, with: bytes(tag.count))
        output.replaceSubrange(0..<4, with: bytes(output.count))
        output.replaceSubrange(84..<100, with: Array(repeating: 0, count: 16)) // Profile ID is now unset.
        return Data(output)
    }

    static func data(width: Int = 400, height: Int = 200, jpeg: Bool = false,
                     orientation: UInt32 = 1, displayP3: Bool = false,
                     alpha: CGFloat = 1, quadrants: Bool = false) -> Data {
        let space = CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.3, 0.1, alpha])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if quadrants {
            let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1]]
            for index in 0..<4 {
                context.setFillColor(CGColor(colorSpace: space, components: colors[index])!)
                context.fill(CGRect(x: (index % 2) * width / 2, y: (index / 2) * height / 2,
                                    width: width / 2, height: height / 2))
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data,
            (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
            [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func jxl(premultiplied: Bool = false, width: Int = 16, height: Int = 16,
                    orientation: UInt32 = 1, rgba: [UInt8]? = nil, icc: Data? = nil,
                    container: Bool = false, grayscale: Bool = false) -> Data {
        let encoder = JxlEncoderCreate(nil)!
        defer { JxlEncoderDestroy(encoder) }
        if container { precondition(JxlEncoderUseContainer(encoder, 1) == JXL_ENC_SUCCESS) }
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width); info.ysize = UInt32(height)
        info.orientation = JxlOrientation(rawValue: orientation)
        info.bits_per_sample = 8; info.num_color_channels = grayscale ? 1 : 3
        info.num_extra_channels = 1; info.alpha_bits = 8
        info.alpha_premultiplied = premultiplied ? 1 : 0
        info.uses_original_profile = 1
        precondition(JxlEncoderSetBasicInfo(encoder, &info) == JXL_ENC_SUCCESS)
        var alpha = JxlExtraChannelInfo()
        JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha)
        alpha.alpha_premultiplied = premultiplied ? 1 : 0
        precondition(JxlEncoderSetExtraChannelInfo(encoder, 0, &alpha) == JXL_ENC_SUCCESS)
        if let icc {
            let status = icc.withUnsafeBytes {
                JxlEncoderSetICCProfile(encoder, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count)
            }
            precondition(status == JXL_ENC_SUCCESS)
        } else {
            var color = JxlColorEncoding()
            JxlColorEncodingSetToSRGB(&color, grayscale ? 1 : 0)
            precondition(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS)
        }
        let settings = JxlEncoderFrameSettingsCreate(encoder, nil)!
        precondition(JxlEncoderSetFrameLossless(settings, 1) == JXL_ENC_SUCCESS)
        var format = JxlPixelFormat(num_channels: grayscale ? 2 : 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)
        let pixel: [UInt8] = [premultiplied ? 128 : 255, 0, 0, 128]
        let pixels = rgba ?? Array(repeating: pixel, count: width * height).flatMap { $0 }
        precondition(pixels.count == width * height * 4)
        let samples = grayscale ? stride(from: 0, to: pixels.count, by: 4).flatMap { [pixels[$0], pixels[$0 + 3]] } : pixels
        let status = samples.withUnsafeBytes { JxlEncoderAddImageFrame(settings, &format, $0.baseAddress, $0.count) }
        precondition(status == JXL_ENC_SUCCESS)
        JxlEncoderCloseInput(encoder)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { output.deallocate() }
        var next: UnsafeMutablePointer<UInt8>? = output
        var available = 65536
        precondition(JxlEncoderProcessOutput(encoder, &next, &available) == JXL_ENC_SUCCESS)
        return Data(bytes: output, count: 65536 - available)
    }
}
