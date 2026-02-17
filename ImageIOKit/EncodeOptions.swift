//
//  EncodeOptions.swift
//  ImageIOKit
//

import Foundation

/// Options that control how an image is encoded.
public struct EncodeOptions {

    /// Compression quality from 0.0 (smallest file) to 1.0 (best quality).
    /// Default is 0.85.
    public var quality: Double

    public init(quality: Double = 0.85) {
        self.quality = max(0.0, min(1.0, quality))
    }
}
