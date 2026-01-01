//
//  ImageIOKit.swift
//  ImageIOKitExample
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation
import CoreGraphics
import ImageIO
import UIKit

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

    /// The pixel dimensions of this image. (Will default to .zero before the image is loaded)
    public private(set) var imageSize: CGSize = .zero

    /// The color model of the image if known.
    public private(set) var colorModel: ImageColorModel?

    /// The color profile of the image if known.
    public private(set) var colorProfile: String?

    /// The type of the image (such as "com.apple.icns"). (Nil until the image has been loaded)
    public var type: String? {
        guard let imageSource else { return nil }
        return CGImageSourceGetType(imageSource) as String?
    }

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
    /// This is called automatically normally when `loadImmediately` in the `init` methods are `true`, but this can be manually deferred in order to control when a potential IO blocking operation occurs.
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
        // While we can use ImageIO to verify the image data's state, for speediness, let's just
        // rely on fetching the image size as that alone is a valid guarantee.
        guard let imageSource,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return false }
        self.imageSize = CGSize(width: width, height: height)

        // While the image size is mandatory, save some of the more common properties while we have the data.
        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            self.colorModel = ImageColorModel(colorModel: colorModel)
        }
        if let colorProfile = properties[kCGImagePropertyProfileName] as? String {
            self.colorProfile = colorProfile
        }

        // Everything passed, so the image is now sucessfully loaded
        self.imageSource = imageSource
        isLoaded = true
        return true
    }

    /// Generates a downscaled copy of the original image, optimistically avoiding decoding
    /// the whole original image into memory if possible.
    /// - Parameter size: The preferred bounding size that the thumbnail will scale to fit in.
    /// - Returns: The downscaled image if successful, nil otherwise.
    public func makeThumbnail(fittingSize size: CGSize) -> UIImage? {
        guard let imageSource else { return nil }

        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(newSize.width, newSize.height)
        ] as CFDictionary

        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }
        return UIImage(cgImage: cgThumbnail)
    }
}
