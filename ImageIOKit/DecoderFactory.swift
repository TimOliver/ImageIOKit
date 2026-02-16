//
//  DecoderFactory.swift
//  ImageIOKit
//
//  Creates format-specific decoders based on magic number detection.
//  Uses ImageFileFormat for format identification and maps each format
//  to its corresponding decoder type.
//

import Foundation

public enum DecoderFactory {

    /// Creates the appropriate decoder for the given file URL.
    /// Tries format detection by file extension first, then by magic bytes.
    public static func decoder(for url: URL) -> (any ImageDecoder)? {
        // Try by extension first (fast path)
        if let format = ImageFileFormat.detect(from: url) {
            return createDecoder(format: format, url: url)
        }

        // Fall back to magic number detection
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let format = ImageFileFormat.detect(from: data) else { return nil }
        return createDecoder(format: format, url: url)
    }

    /// Creates the appropriate decoder for the given in-memory data.
    /// Detects format via magic bytes.
    public static func decoder(for data: Data) -> (any ImageDecoder)? {
        guard let format = ImageFileFormat.detect(from: data) else { return nil }
        return createDecoder(format: format, data: data)
    }

    /// Returns the decoder type for a given format.
    public static func decoderType(for format: ImageFileFormat) -> (any ImageDecoder.Type)? {
        switch format {
        case .jpeg: return JPEGDecoder.self
        case .png:  return PNGDecoder.self
        case .webp: return WebPDecoder.self
        case .avif: return AVIFDecoder.self
        case .jpegXL: return JXLDecoder.self
        case .heic: return nil // HEIC handled via ImageIO fallback
        }
    }

    // MARK: - Private

    private static func createDecoder(format: ImageFileFormat, url: URL) -> (any ImageDecoder)? {
        switch format {
        case .jpeg: return JPEGDecoder(url: url)
        case .png:  return PNGDecoder(url: url)
        case .webp: return WebPDecoder(url: url)
        case .avif: return AVIFDecoder(url: url)
        case .jpegXL: return JXLDecoder(url: url)
        case .heic: return nil
        }
    }

    private static func createDecoder(format: ImageFileFormat, data: Data) -> (any ImageDecoder)? {
        switch format {
        case .jpeg: return JPEGDecoder(data: data)
        case .png:  return PNGDecoder(data: data)
        case .webp: return WebPDecoder(data: data)
        case .avif: return AVIFDecoder(data: data)
        case .jpegXL: return JXLDecoder(data: data)
        case .heic: return nil
        }
    }
}
