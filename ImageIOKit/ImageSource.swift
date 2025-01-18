//
//  ImageIOKit.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation
import CoreGraphics
import ImageIO

/// A wrapper for `CGImageSourceRef`, an image source represents
/// the arbitrary location of an compressed image file, whether it
/// is currently stored on disk, or loaded in memory in its compressed state.
/// Image sources can be used to efficiently decode images into memory,
/// or be used to transform image data to other file formats, avoiding
/// incurring the memory hit of a full decode as much as possible.
public final class ImageSource {

    /// The URL for the image file if it was loaded from disk.
    public private(set) var url: URL?

    /// The source data for the image file.
    public private(set) var data: Data?

    // MARK: - Private Properties

    // The underlying image source, pointing at the image data.
    // Lazily loaded once it is needed for processing.
    private var imageSource: CGImageSource?

    // MARK: - Init

    /// Create a new image source instance with the provided data
    /// - Parameter data: An opaque data object representing a compressed image file.
    init?(data: Data) {
        guard isValidFileFormat(data: data) else { return nil }
        self.data = data
    }

    /// Create a new image source instance with a path to an image file
    /// - Parameter data: A local file path to an image file.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]),
              isValidFileFormat(data: data) else { return nil }
        self.url = url
    }

    // MARK: - Private

    /// Checks the header of the file to see if it is a file format supported by this framework.
    /// - Parameter data: A data object representing compressed image file data
    private func isValidFileFormat(data: Data) -> Bool {
        // Fetch the first byte from memory
        guard let firstByte = data.withUnsafeBytes({ $0.first}) else { return false }

        // See if any of our supported file magic numbers start with that byte
        let possibleFileFormats = ImageFileFormat.allCases.filter { $0.magicNumber.first == firstByte }
        guard !possibleFileFormats.isEmpty else { return false}

        return true
    }
}
