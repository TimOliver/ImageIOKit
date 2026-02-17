//
//  EncoderFactory.swift
//  ImageIOKit
//
//  Creates format-specific encoders based on the target ImageFileFormat.
//

import Foundation

public enum EncoderFactory {

    /// Creates the appropriate encoder for the given format.
    /// Returns `nil` for formats that don't support encoding (e.g., HEIC).
    public static func encoder(for format: ImageFileFormat) -> (any ImageEncoder)? {
        switch format {
        case .jpeg:   return JPEGEncoder()
        case .png:    return PNGEncoder()
        case .webp:   return WebPEncoder()
        case .avif:   return AVIFEncoder()
        case .jpegXL: return JXLEncoder()
        case .heic:   return nil
        }
    }

    /// Returns the encoder type for a given format.
    public static func encoderType(for format: ImageFileFormat) -> (any ImageEncoder.Type)? {
        switch format {
        case .jpeg:   return JPEGEncoder.self
        case .png:    return PNGEncoder.self
        case .webp:   return WebPEncoder.self
        case .avif:   return AVIFEncoder.self
        case .jpegXL: return JXLEncoder.self
        case .heic:   return nil
        }
    }
}
