//
//  ImageFileFormat.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 18/1/2025.
//

import Foundation
import UniformTypeIdentifiers

/// A list of all supported image file formats, and their respective metadata
public enum ImageFileFormat: CaseIterable, Sendable {
    case jpeg
    case png
    case webp
    case heic
    case avif
    case jpegXL

    /// The officially recognized path extensions
    /// for each image file format.
    public var fileExtensions: [String] {
        switch self {
        case .jpeg: return ["jpeg", "jpg", "jpe", "jif", "jfif", "jfi"]
        case .png: return ["png"]
        case .webp: return ["webp"]
        case .heic: return ["heif", "heifs", "heic", "heics", "avci", "avcs", "hif"]
        case .avif: return ["avif"]
        case .jpegXL: return ["jxl"]
        }
    }

    /// The magic numbers that denote each file format
    /// (For formats with dynamic portions of their number,
    /// use 0x00 to denote bytes that should be skipped)
    public var magicNumbers: [[UInt8]] {
        switch self {
        case .jpeg: return [[0xff, 0xd8, 0xff]]
        case .png: return [[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]]
        case .webp: return [[0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38]]
        case .heic: return ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].map {
            [0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70] + Array($0.utf8)
        }
        case .avif: return ["avif", "avis"].map {
            [0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70] + Array($0.utf8)
        }
        case .jpegXL: return [[0xFF, 0x0A], [0x00, 0x00, 0x00, 0x0C, 0x4A,
                                             0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]]
        }
    }

    /// Whether this file format is currently supported by ImageIO on this device's OS version
    public var isSupportedByOSVersion: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        switch self {
        case .jpeg, .png: return true
        case .heic: return version >= 11
        case .webp: return version >= 14
        case .avif, .jpegXL: return version >= 17
        }
    }

    /// Whether this format is always opaque (no alpha channel support).
    public var isOpaque: Bool {
        self == .jpeg
    }

    /// The Uniform Type Identifier string for this format, used by CGImageDestination.
    public var uniformTypeIdentifier: CFString {
        switch self {
        case .jpeg:   return UTType.jpeg.identifier as CFString
        case .png:    return UTType.png.identifier as CFString
        case .webp:   return UTType.webP.identifier as CFString
        case .heic:   return UTType.heic.identifier as CFString
        case .avif:   return "public.avif" as CFString
        case .jpegXL: return "public.jpeg-xl" as CFString
        }
    }
}

// MARK: - Format Validation

extension ImageFileFormat {

    /// Checks the file extension of the provided file path and
    /// returns true if it is a recognized supported file format.
    /// - Parameter url: The absolute/relative url to an image file on disk.
    /// - Returns: Whether the file path extension is a supported format or not
    public static func isValidFileName(at url: URL) -> Bool {
        isValidFileName(url.lastPathComponent)
    }

    /// Checks the file extension of the provided file name and
    /// returns true if it is a recognized supported file format.
    /// - Parameter fileName: The name of an image file.
    /// - Returns: Whether the file path extension is a supported format or not
    public static func isValidFileName(_ fileName: String) -> Bool {
        guard let fileExtension = fileName.split(separator: ".").last?.lowercased() else { return false }
        return allCases.contains { $0.fileExtensions.contains(fileExtension) }
    }

    /// Checks the header of the file to see if it is a file format supported by this framework.
    /// - Parameter data: A data object representing compressed image file data.
    /// - Returns: Whether the data's magic bytes match a supported format.
    public static func isValidFileFormat(data: Data) -> Bool {
        detect(from: data) != nil
    }

    /// Detects the image format from the magic bytes in the data header.
    /// - Parameter data: Compressed image file data.
    /// - Returns: The detected format, or `nil` if unrecognized.
    public static func detect(from data: Data) -> ImageFileFormat? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for format in allCases where format != .heic && format != .avif {
                for signature in format.magicNumbers where bytes.count >= signature.count {
                    if signature.enumerated().allSatisfy({ index, byte in byte == 0 || bytes[index] == byte }) {
                        return format
                    }
                }
            }
            // ISO BMFF brands identify HEIF-family codecs; box sizes do not.
            func uint32(_ offset: Int) -> UInt64 {
                (0..<4).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
            }
            func brand(_ offset: Int) -> String {
                String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            }
            var offset = 0
            while bytes.count - offset >= 8 {
                var length = uint32(offset)
                var header = 8
                if length == 1 {
                    guard bytes.count - offset >= 16 else { return nil }
                    length = (uint32(offset + 8) << 32) | uint32(offset + 12)
                    header = 16
                } else if length == 0 {
                    length = UInt64(bytes.count - offset)
                }
                guard length >= header, length <= UInt64(bytes.count - offset) else { return nil }
                let end = offset + Int(length)
                if brand(offset + 4) == "ftyp" {
                    guard Int(length) >= header + 8, (Int(length) - header) % 4 == 0 else { return nil }
                    var brands = [brand(offset + header)]
                    var position = offset + header + 8 // Skip the minor version.
                    while position < end {
                        brands.append(brand(position))
                        position += 4
                    }
                    if brands.contains(where: { $0 == "avif" || $0 == "avis" }) { return .avif }
                    let heifBrands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]
                    return brands.contains(where: heifBrands.contains) ? .heic : nil
                }
                offset = end
            }
            return nil
        }
    }

    /// Detects the image format from a file URL's extension.
    /// - Parameter url: Path to an image file.
    /// - Returns: The detected format, or `nil` if the extension is unrecognized.
    public static func detect(from url: URL) -> ImageFileFormat? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.fileExtensions.contains(ext) }
    }
}
