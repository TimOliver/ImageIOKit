//
//  ImageFileFormat.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 18/1/2025.
//

import Foundation

/// A list of all supported image file formats, and their respective metadata
public enum ImageFileFormat: CaseIterable {
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
        case .heic: return [[0x00, 0x00, 0x00, 0x24, 0x66, 0x74, 0x79, 0x70]]
        case .avif: return [[0x00, 0x00, 0x00, 0x00, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66]]
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
    /// - Parameter data: A data object representing compressed image file data
    public static func isValidFileFormat(data: Data) -> Bool {
        // Loop through the possible formats and compare each byte to guarantee a match
        if ImageFileFormat.allCases.first(where: { format in
            for magicNumber in format.magicNumbers {
                let magicNumberLength = magicNumber.count
                let buffer = data.prefix(magicNumber.count)
                for index in 0..<magicNumberLength {
                    let byte = magicNumber[index]
                    if byte == 0x00 { continue } // Treat 0 values as wildcards
                    if byte != buffer[index] { break }
                }
            }
            return true
        }) != nil { return true }

        return false
    }

}
