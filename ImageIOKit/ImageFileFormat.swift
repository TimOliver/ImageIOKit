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

    /// The magic number that identifies each format in its header
    /// (For formats with dynamic portions of their number,
    /// use 0x00 to denote bytes that should be skipped)
    public var magicNumber: [UInt8] {
        switch self {
        case .jpeg: return [0xff, 0xd8, 0xff]
        case .png: return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        case .webp: return [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38]
        case .heic: return [0x00, 0x00, 0x00, 0x24, 0x66, 0x74, 0x79, 0x70]
        case .avif: return []
        case .jpegXL: return []
        }
    }
}
