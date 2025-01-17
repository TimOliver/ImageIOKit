//
//  ImageIOKit.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation
import CoreGraphics
import ImageIO

/// A wrapper for `CGImageSourceRef`, an image source represents the location
/// of an undecoded image file, whether it is on disk, or in memory.
/// Image sources can be used to efficiently decode images into memory,
/// or be used to transform image data to other file formats without
/// incurring the memory hit of a full decode.
public final class ImageSource {

    // The underlying image source, pointing at the image data.
    private let imageSource: CGImageSource

    /// Create a new image source instance with the provided data
    /// - Parameter data: An opaque data object representing a compressed image file.
    init?(data: Data) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        guard let source else { return nil }
        imageSource = source
    }

    /// Create a new image source instance with a path to an image file
    /// - Parameter data: A local file path to an image file.
    init?(url: URL) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let source else { return nil }
        imageSource = source
    }
}
