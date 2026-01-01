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
    public private(set) var data: Data?

    /// For images sources that didn't have their headers loaded upon init,
    /// this property can be used to check this state to manually load the headers or not.
    public private(set) var isLoaded: Bool = false

    /// The pixel dimensions of this image. (Nil until the image is loaded)
    public private(set) var size: CGSize?

    // MARK: - Private Properties

    // The underlying image source, pointing at the image data.
    // Lazily loaded once it is needed for processing.
    private var imageSource: CGImageSource?

    // MARK: - Init

    /// Create a new image source instance with the provided data.
    /// - Parameter data: An opaque data object representing a compressed image file.
    /// - Parameter loadImmediately: Loads the header data, making the image metadata available immediately.
    ///                              This can be manually deferred until calling `loadImageData` in performance sensitive circumstances.
    /// - Return: Returns a new image source instance.
    ///           If `loadImmediately` is true, and the image data is invalid, `nil` is returned instead.
    init?(data: Data, loadImmediately: Bool = true) {
        self.data = data
        if loadImmediately, !loadImageData() { return nil }
    }

    /// Create a new image source instance with a path to an image file
    /// - Parameter url: A local file path to an image file.
    /// - Parameter loadImmediately: Loads the header data, making the image metadata available immediately.
    ///                              This can be manually deferred until calling `loadImageData` in performance sensitive circumstances.
    /// - Return: Returns a new image source instance.
    ///           If `loadImmediately` is true, and the image data is invalid, `nil` is returned instead.
    init?(url: URL, loadImmediately: Bool = true) {
        self.url = url
        if loadImmediately, !loadImageData() { return nil }
    }

    /// Loads the header data for the provided image file and configures this object to start reading information from it.
    /// This is called automatically normally when `loadImmediately` is `true`, but this can be manually deferred in order to control potential IO blocking operations.
    /// - Returns: `true` if the image header was successfully read, or `false` if it failed.
    public func loadImageData() -> Bool {
        guard !isLoaded else { return true }

        // Based on whether we were provided with a url or data, attempt to load with ImageIO
        let imageSource: CGImageSource?
        if let url = self.url {
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else if let data = self.data {
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            fatalError("ImageSource: A load was attempted without a valid image data or URL object.")
        }

        // `CGImageSourceCreate` will still produce a non-nil value even if the image data was invalid.
        // So we must verify if we have actual image data in there or not. We'll do this by querying for the image size.
        guard let imageSource,
              let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        self.size = CGSize(width: width, height: height)

        // Everything passed, so the image is now sucessfully loaded
        self.imageSource = imageSource
        isLoaded = true
        return true
    }
}
