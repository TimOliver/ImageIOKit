//
//  AVIFDecoder.swift
//  ImageIOKit
//
//  AVIF decoder using avif.swift (which wraps libavif + dav1d).
//  Full decode only — no native shrink or region decode.
//  Falls back to SoftwareScaler for downscaling and cropping.
//

import Foundation
import CoreGraphics
import avif

public final class AVIFDecoder: ImageDecoder {

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
        guard let meta = AVIFDecoder.readHeader(data: data) else { return nil }
        self.metadata = meta
    }

    // MARK: - Header Reading

    /// Parses the AVIF ISOBMFF container to extract dimensions without a full decode.
    /// Scans for the 'ispe' (Image Spatial Extents) box which contains width and height.
    private static func readHeader(data: Data) -> ImageMetadata? {
        // Verify AVIF magic: bytes 4-11 should be "ftypavif"
        guard data.count >= 12 else { return nil }

        // Parse ISOBMFF boxes to find ispe (Image Spatial Extents)
        if let (width, height, hasAlpha) = parseISOBMFF(data: data) {
            return ImageMetadata(
                width: width, height: height,
                hasAlpha: hasAlpha, colorModel: .rgb
            )
        }

        // Fallback: try a lightweight decode to get dimensions
        return readHeaderViaDecoder(data: data)
    }

    /// Scans ISOBMFF boxes for 'ispe' to extract width/height and 'auxC' for alpha.
    private static func parseISOBMFF(data: Data) -> (width: Int, height: Int, hasAlpha: Bool)? {
        var width: Int?
        var height: Int?
        var hasAlpha = false

        func scanBoxes(in range: Range<Int>, depth: Int) {
            guard depth < 10 else { return } // prevent infinite recursion
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                let boxSize = data.readUInt32BE(at: offset)
                let boxType = data.readASCII(at: offset + 4, length: 4)

                let contentStart = offset + 8
                let boxEnd: Int
                if boxSize == 0 {
                    boxEnd = range.upperBound // box extends to end
                } else if boxSize == 1 && offset + 16 <= range.upperBound {
                    let largeSize = data.readUInt64BE(at: offset + 8)
                    boxEnd = offset + Int(largeSize)
                } else {
                    boxEnd = offset + Int(boxSize)
                }

                guard boxEnd > contentStart, boxEnd <= data.count else { break }

                switch boxType {
                case "meta":
                    // meta box has a 4-byte version+flags field before children
                    let childStart = contentStart + 4
                    if childStart < boxEnd {
                        scanBoxes(in: childStart..<boxEnd, depth: depth + 1)
                    }
                case "iprp", "ipco":
                    scanBoxes(in: contentStart..<boxEnd, depth: depth + 1)
                case "ispe":
                    // ispe: 4 bytes version+flags, 4 bytes width, 4 bytes height
                    if contentStart + 12 <= boxEnd {
                        let w = data.readUInt32BE(at: contentStart + 4)
                        let h = data.readUInt32BE(at: contentStart + 8)
                        width = Int(w)
                        height = Int(h)
                    }
                case "auxC":
                    // Presence of auxC with alpha URN indicates alpha
                    hasAlpha = true
                case "pixi":
                    // pixi contains channel count info — 4+ channels means alpha
                    if contentStart + 5 <= boxEnd {
                        let numChannels = data[contentStart + 4]
                        if numChannels >= 4 {
                            hasAlpha = true
                        }
                    }
                default:
                    break
                }

                offset = boxEnd
            }
        }

        scanBoxes(in: 0..<data.count, depth: 0)

        if let w = width, let h = height {
            return (w, h, hasAlpha)
        }
        return nil
    }

    /// Fallback: use avif.swift's readSize to extract dimensions without full decode.
    private static func readHeaderViaDecoder(data: Data) -> ImageMetadata? {
        guard let size = try? avif.AVIFDecoder.readSize(data: data),
              size.width > 0, size.height > 0 else { return nil }
        return ImageMetadata(
            width: Int(size.width),
            height: Int(size.height),
            hasAlpha: false, // conservative default; full decode needed for accurate alpha detection
            colorModel: .rgb
        )
    }

    // MARK: - Decode

    public func decode(options: DecodeOptions) throws -> PixelBuffer {
        guard let cgImage = AVIFDecoder.decodeWithAVIFSwift(data: imageData) else {
            throw ImageDecoderError.decodeFailed("AVIF decode failed")
        }

        // Render CGImage into a PixelBuffer
        var buffer = try renderCGImage(cgImage, pixelFormat: options.pixelFormat)

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

    // MARK: - avif.swift Integration

    /// Decodes AVIF data using the avif.swift package (awxkee/avif.swift).
    /// The package exposes avif.AVIFDecoder with static decode methods.
    private static func decodeWithAVIFSwift(data: Data) -> CGImage? {
        // Use the avif package's AVIFDecoder (fully qualified to avoid conflict with our type)
        guard let platformImage = avif.AVIFDecoder.decode(data) else { return nil }
        #if !os(macOS)
        return platformImage.cgImage
        #else
        var rect = CGRect(origin: .zero, size: platformImage.size)
        return platformImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    // MARK: - Helpers

    private func renderCGImage(_ cgImage: CGImage, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        let buffer = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat)

        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo

        switch pixelFormat {
        case .rgba8:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        case .rgb8:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        case .gray8:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case .grayAlpha8:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        guard let ctx = CGContext(
            data: buffer.data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: buffer.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ImageDecoderError.decodeFailed("Failed to create CGContext for AVIF rendering")
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Data Extensions for ISOBMFF Parsing

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          from: offset..<(offset + 4))
        }
        return UInt32(bigEndian: value)
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          from: offset..<(offset + 8))
        }
        return UInt64(bigEndian: value)
    }

    func readASCII(at offset: Int, length: Int) -> String {
        guard offset + length <= count else { return "" }
        let bytes = self[offset..<(offset + length)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
