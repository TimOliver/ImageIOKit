//
//  DecoderCapabilities.swift
//  ImageIOKit
//

import Foundation

/// Describes the native decode capabilities of a source.
public struct DecoderCapabilities: OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The source can decode a sub-region without decoding the full image
    /// (JPEG via libjpeg crop_scanline).
    public static let regionDecode = DecoderCapabilities(rawValue: 1 << 1)
}
