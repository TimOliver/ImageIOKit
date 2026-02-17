//
//  ImageEncoder.swift
//  ImageIOKit
//
//  Shared types used by image encode operations:
//  EncodeOptions and errors.
//

import Foundation

// MARK: - Encode Options

/// Options that control how an image is encoded.
public struct EncodeOptions {

    /// Compression quality from 0.0 (smallest file) to 1.0 (best quality).
    /// Default is 0.85.
    public var quality: Double

    public init(quality: Double = 0.85) {
        self.quality = max(0.0, min(1.0, quality))
    }
}

// MARK: - Errors

/// Errors produced by image encode operations.
public enum ImageEncoderError: Error {
    /// The encode operation failed. The associated string provides details.
    case encodeFailed(String)
}
