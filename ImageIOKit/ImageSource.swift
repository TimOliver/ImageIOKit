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

/// The types of color modes in which an image may be encoded.
public enum ImageColorModel: Sendable {
    case rgb
    case grayscale
    case cmyk
    case lab

    internal init?(colorModel: String) {
        switch (colorModel as CFString) {
        case kCGImagePropertyColorModelRGB: self = .rgb
        case kCGImagePropertyColorModelGray: self = .grayscale
        case kCGImagePropertyColorModelCMYK: self = .cmyk
        case kCGImagePropertyColorModelLab: self = .lab
        default: return nil
        }
    }
}

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

    /// Display-oriented pixel dimensions, after applying EXIF rotation or mirroring.
    /// Defaults to `.zero` before the image is loaded.
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
    /// Upright JPEG sources support this via TurboJPEG. Rotated or mirrored
    /// sources currently use ImageIO's orientation-normalizing fallback.
    public var isRegionDecodable: Bool {
        fileFormat == .jpeg && orientation == .up
    }

    /// Planning estimate for a full-resolution RGBA decode. Not a hard memory limit;
    /// codec working memory and system caches vary with the image and OS.
    public var estimatedDecodeMemory: Int {
        (try? estimatedDecodeMemory(targetSize: nil)) ?? Int.max
    }

    /// Estimates additional bytes for `decode(targetSize:cropRect:pixelFormat:)`.
    /// Includes the output, rendering intermediates, and a full-resolution codec
    /// allowance even for thumbnails/regions, since codecs can fall back to full decode.
    /// Excludes compressed input and previously cached images. Returns zero before loading.
    public func estimatedDecodeMemory(targetSize: CGSize? = nil, cropRect: CGRect? = nil,
                                      pixelFormat: PixelBuffer.PixelFormat = .rgba8) throws -> Int {
        guard isLoaded else { return 0 }
        let crop = try cropRect.map { try SoftwareScaler.clampedCrop($0, in: imageSize) }
        let output = try SoftwareScaler.outputSize(for: crop?.size ?? imageSize, fitting: targetSize)
        let sourcePixels = Double(imageSize.width) * Double(imageSize.height)
        let outputPixels = Double(output.width) * Double(output.height)
        let codecBytesPerPixel: Double = fileFormat == .jpeg ? 8 : 16
        let conversionBytes: Double = (pixelFormat == .rgb8 || pixelFormat == .grayAlpha8) ? 4 : 0
        let bytes = sourcePixels * codecBytesPerPixel
            + outputPixels * (Double(pixelFormat.bytesPerPixel) + conversionBytes)
        guard bytes.isFinite, bytes < Double(Int.max) else { return Int.max }
        return Int(bytes.rounded(.up))
    }

    // MARK: - Internal Properties

    /// The underlying CGImageSource.
    var cgImageSource: CGImageSource?

    private(set) var orientation: CGImagePropertyOrientation = .up

    /// Per-source cache; its key is a Sendable value in Swift 6.
    static let fullDecodeCacheKey = "fullDecode"
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
    public init?(data: Data, loadImmediately: Bool = true) {
        self.data = data
        if loadImmediately, !loadImageData() { return nil }
    }

    /// Create a new image source instance with a path to an image file
    /// - Parameter url: A local file path to an image file.
    /// - Parameter loadImmediately: Loads the header data, making the image metadata available immediately.
    ///                              This can be manually deferred until calling `loadImageData` in performance sensitive circumstances.
    /// - Return: Returns a new image source instance.
    ///           If `loadImmediately` is true, and the image data is invalid, `nil` is returned instead.
    public init?(url: URL, loadImmediately: Bool = true) {
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
        } else if let data = self.data {
            source = CGImageSourceCreateWithData(data as CFData, nil)
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

        // ImageIO's parsed source type is authoritative, regardless of filename.
        if let uti = CGImageSourceGetType(source) as String? {
            self.fileFormat = ImageFileFormat.allCases.first {
                ($0.uniformTypeIdentifier as String) == uti
            }
        }

        self.cgImageSource = source
        self.orientation = CGImagePropertyOrientation(rawValue:
            (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up
        let swapsAxes = orientation.rawValue >= 5
        self.imageSize = CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
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
