//
//  ImageSource.swift
//  ImageIOKit
//
//  Wraps Apple's CGImageSource for all decode and thumbnail operations.
//  Delegates to JPEGRegionDecoder for JPEG region decode (tiling)
//  and JXLReconstructor for lossless JXL → JPEG reconstruction.
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

    /// Whether this image has an alpha channel or not.
    public private(set) var hasAlpha: Bool = false

    /// The color model of the image if known.
    public private(set) var colorModel: ImageColorModel?

    /// The color profile of the image if known.
    public private(set) var colorProfile: String?

    /// The detected file format of the image.
    public private(set) var fileFormat: ImageFileFormat?

    /// Whether this source supports sub-region decode without decoding the full image.
    /// Only JPEG sources support this (via libjpeg crop_scanline).
    public var isRegionDecodable: Bool {
        fileFormat == .jpeg
    }

    /// Estimated peak bytes required for a full-resolution decode of this image,
    /// including both the output bitmap and ImageIO's transient decompression buffers.
    ///
    /// Multipliers are calibrated empirically per format against ImageIO:
    /// - **JPEG**: ~0.5x — no alpha, compact internal representation
    /// - **PNG/WebP/HEIC/AVIF/JPEG-XL**: ~1.25x — moderate decompression overhead
    ///
    /// Use this to decide whether to decode images concurrently or serially
    /// (e.g. compare against `os_proc_available_memory()`).
    public var estimatedDecodeMemory: Int {
        let bitmapBytes = Int(imageSize.width) * Int(imageSize.height) * 4
        let multiplier: Double = switch fileFormat {
        case .jpeg:   0.5
        default:      1.25
        }
        return Int(Double(bitmapBytes) * multiplier)
    }

    // MARK: - Internal Properties

    /// The underlying CGImageSource.
    var cgImageSource: CGImageSource?

    /// Cached full-resolution CGImage. Statically defined so NSCache can
    /// manage it and purge under memory pressure. Shared across
    /// all threads
    static let fullDecodeCacheKey = "fullDecode" as NSString
    let fullDecodeCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 1
        return cache
    }()

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
    @discardableResult
    public func loadImageData() -> Bool {
        guard !isLoaded else { return true }

        // Create CGImageSource
        let source: CGImageSource?
        if let url = self.url {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
            self.fileFormat = ImageFileFormat.detect(from: url)
        } else if let data = self.data {
            source = CGImageSourceCreateWithData(data as CFData, nil)
            self.fileFormat = ImageFileFormat.detect(from: data)
        } else {
            fatalError("ImageSource: A load was attempted without a valid image data or URL object.")
        }

        guard let source else { return false }

        // Read properties from the image header
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return false }

        // Detect format from UTI if not already detected via magic bytes
        if self.fileFormat == nil, let uti = CGImageSourceGetType(source) as String? {
            self.fileFormat = ImageFileFormat.allCases.first {
                ($0.uniformTypeIdentifier as String) == uti
            }
        }

        self.cgImageSource = source
        self.imageSize = CGSize(width: width, height: height)
        self.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false

        if let colorModelString = properties[kCGImagePropertyColorModel] as? String {
            self.colorModel = ImageColorModel(colorModel: colorModelString)
        }
        if let profileName = properties[kCGImagePropertyProfileName] as? String {
            self.colorProfile = profileName
        }

        self.isLoaded = true
        return true
    }

    // MARK: - JPEG Reconstruction

    /// For JXL images that were created by losslessly recompressing a JPEG,
    /// reconstructs the exact original JPEG bitstream. Returns `nil` if the
    /// source is not JXL or was not derived from a JPEG.
    public func reconstructJPEG() -> Data? {
        guard fileFormat == .jpegXL else { return nil }

        let reconstructor: JXLReconstructor?
        if let url {
            reconstructor = JXLReconstructor(url: url)
        } else if let data {
            reconstructor = JXLReconstructor(data: data)
        } else {
            return nil
        }

        return reconstructor?.reconstructJPEG()
    }
}

// MARK: - Quick Look

extension ImageSource {
    @objc func debugQuickLookObject() -> Any? {
        if let thumbnail = makeThumbnail(fittingSize: CGSize(width: 512, height: 512)) {
            return thumbnail
        }
        if isLoaded {
            let format = fileFormat?.fileExtensions.first?.uppercased() ?? "Unknown"
            return "\(format) \(Int(imageSize.width))×\(Int(imageSize.height))"
        }
        return "ImageSource (not loaded)"
    }
}
