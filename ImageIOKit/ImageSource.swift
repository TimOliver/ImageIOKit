//
//  ImageIOKit.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation
import CoreGraphics
import ImageIO

/// An image source represents an arbitrary location of a compressed
/// image file, whether it be a file on disk, or directly in memory.
/// 
/// Image sources can be used to efficiently decode the full bitmap into memory,
/// or be used to transform image data to other file formats, avoiding
/// incurring the memory hit of a full decode as much as possible.
///  
/// This class aims to be as efficient and memory light as possible,
/// only performing heavy loading operations on demand.
public final class ImageSource {

    /// The local file path to the image file, if it was loaded from disk.
    public private(set) var url: URL?

    /// The compressed image's data, if this object was created from an in-memory image.
    /// If a file URL was specified, this property returns a memory-mapped pointer to the on-disk data.
    public private(set) var data: Data?

    /// For images sources that didn't have their headers loaded upon init,
    /// this property can be used to check this state to manually load the headers or not.
    public private(set) var isLoaded: Bool = false

    // MARK: - Private Properties

    // The underlying image source, pointing at the image data.
    // Lazily loaded once it is needed for processing.
    private var imageSource: CGImageSource?

    // MARK: - Init

    /// Create a new image source instance with the provided data.
    /// - Parameter data: An opaque data object representing a compressed image file.
    /// - Parameter loadImmediately: Loads the header data for the image in this initializer.
    ///                              This can be manually deferred until calling `loadImageData` if required.
    /// - Return: Returns a new image source instance.
    ///           If `loadImmediately` is true, and the image data is invalid, `nil` is returned instead.
    init?(data: Data, loadImmediately: Bool = true) {
        self.data = data
        if loadImmediately, !load() { return nil }
    }

    /// Create a new image source instance with a path to an image file
    /// - Parameter data: A local file path to an image file.
    /// - Parameter loadImmediately: Loads the header data for the image in this initializer.
    ///                              This can be manually deferred until calling `loadImageData` if required.
    /// - Return: Returns a new image source instance.
    ///           If `loadImmediately` is true, and the image data is invalid, `nil` is returned instead.
    init?(url: URL, loadImmediately: Bool = true) {
        self.url = url
        if loadImmediately, !load() { return nil }
    }

    /// Loads the header data for the provided image file and configures this object to start reading information from it.
    /// This is called automatically normally when `loadImmediately` is `true`, but this can be manually deferred if desired in order to maximize performance.
    /// - Returns: `true` if the image header was successfully read, or `false` if it failed.
    public func load() -> Bool {
        guard !isLoaded else { return true }

        // Since we need to read the first few bytes anyway,
        // for files, populate the data property with a memory-mapped pointer
        if let url = self.url {
            self.data = try? Data(contentsOf: url, options: .alwaysMapped)
        }

        // Perform the main magic number check
        guard let data = self.data,
              isValidFileFormat(data: data) else { return false }

        // Now that we've confirmed it's a valid file, load it into ImageIO.
        // Down the line, we'll add more codecs here.
        if let url = self.url {
            self.imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else  {
            self.imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        }
        if self.imageSource == nil { return false }

        isLoaded = true
        return true
    }

    // MARK: - Private

    /// Checks the header of the file to see if it is a file format supported by this framework.
    /// - Parameter data: A data object representing compressed image file data
    private func isValidFileFormat(data: Data) -> Bool {
        // Loop through the possible formats and compare each byte to guarantee a match
        if ImageFileFormat.allCases.first(where: { format in
            for magicNumber in format.magicNumbers {
                let magicNumberLength = magicNumber.count
                let buffer = data.prefix(magicNumber.count)
                for index in 0..<magicNumberLength {
                    let byte = magicNumber[index]
                    if byte == 0x00 { continue } // Treat 0 values as wildcards
                    if byte != buffer[index] { return false }
                }
            }
            return true
        }) != nil { return true }

        return false
    }
}
