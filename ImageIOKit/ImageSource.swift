//
//  ImageSource.swift
//  ImageIOKit
//
//  Facade over format-specific decoders. Preserves the existing public API
//  while delegating to JPEGDecoder, PNGDecoder, WebPDecoder, AVIFDecoder,
//  and JXLDecoder for actual decode work. Adds region decode support.
//

import Foundation
import CoreGraphics
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

    /// The types of downscaling modes that may be used when
    /// creating smaller sized copies of this image.
    public enum DownscaleStrategy {
        case automatic      // Uses native shrink-on-load when available, falls back to software.
        case partialDecode  // Uses codec-level shrink (JPEG scale_denom, JXL DC, WebP use_scaling).
        case fullDecode     // The image is fully decoded and downscaled via Core Graphics manually.
    }

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

    /// The native decode capabilities of the underlying format.
    public var capabilities: DecoderCapabilities {
        guard let decoder else { return [] }
        return type(of: decoder).capabilities
    }

    /// Estimated peak memory (in bytes) for a full-resolution decode.
    /// Use this to decide whether to set a `memoryBudget` on decode options,
    /// or to skip decoding entirely on memory-constrained devices.
    ///
    /// For JXL images, this accounts for libjxl's internal float32 working
    /// buffers which can be ~8x the raw pixel data. For other formats, the
    /// estimate is more conservative (typically ~2x).
    public var estimatedDecodeMemory: Int {
        guard let decoder else { return 0 }
        return decoder.estimatedDecodeMemory
    }

    // MARK: - Private Properties

    /// The format-specific decoder used for all decode operations.
    private var decoder: (any ImageDecoder)?

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

        // Create the appropriate decoder via the factory
        let imageDecoder: (any ImageDecoder)?
        if let url = self.url {
            imageDecoder = DecoderFactory.decoder(for: url)
            self.fileFormat = ImageFileFormat.detect(from: url)
        } else if let data = self.data {
            imageDecoder = DecoderFactory.decoder(for: data)
            self.fileFormat = ImageFileFormat.detect(from: data)
        } else {
            fatalError("ImageSource: A load was attempted without a valid image data or URL object.")
        }

        guard let imageDecoder else { return false }
        let meta = imageDecoder.metadata

        guard meta.width > 0, meta.height > 0 else { return false }

        self.decoder = imageDecoder
        self.imageSize = meta.size
        self.hasAlpha = meta.hasAlpha
        self.colorModel = meta.colorModel
        self.colorProfile = meta.colorProfile
        self.isLoaded = true

        return true
    }

    // MARK: - Thumbnail Generation

    /// Generates a downscaled copy of the original image, optimistically avoiding decoding
    /// the whole original image into memory if possible.
    /// - Parameter size: The preferred bounding size that the thumbnail will scale to fit in.
    /// - Parameter downscaleStrategy: The strategy used to generate the thumbnail.
    /// - Parameter memoryBudget: Maximum bytes the decode is allowed to allocate.
    ///   When exceeded, codecs that support it (e.g. JXL) will fall back to a lower-quality
    ///   but memory-safe decode path. Pass 0 (the default) for no limit.
    /// - Returns: The downscaled image if successful, nil otherwise.
    public func makeThumbnail(fittingSize size: CGSize, downscaleStrategy: DownscaleStrategy = .automatic,
                              memoryBudget: Int = 0) -> UIImage? {
        guard let decoder, isLoaded else { return nil }

        let fitSize = SoftwareScaler.fittingSize(for: imageSize, in: size)
        guard fitSize.width > 0, fitSize.height > 0 else { return nil }

        let options: DecodeOptions
        switch downscaleStrategy {
        case .automatic, .partialDecode:
            options = DecodeOptions(targetSize: fitSize, memoryBudget: memoryBudget)
        case .fullDecode:
            options = DecodeOptions(memoryBudget: memoryBudget)
        }

        guard let pixelBuffer = try? decoder.decode(options: options) else { return nil }

        // For fullDecode strategy, we need to manually scale the full-res buffer
        let outputBuffer: PixelBuffer
        if downscaleStrategy == .fullDecode {
            outputBuffer = SoftwareScaler.scale(pixelBuffer, to: fitSize) ?? pixelBuffer
        } else {
            outputBuffer = pixelBuffer
        }

        guard let cgImage = outputBuffer.makeCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Region Decode

    /// Decodes a specific region of the image, using native region decode when available.
    /// - Parameter rect: The region to decode, in pixel coordinates of the full image.
    /// - Parameter targetSize: Optional target size for the decoded region.
    /// - Returns: The decoded region as a UIImage, or nil on failure.
    public func decodeRegion(_ rect: CGRect, targetSize: CGSize? = nil) -> UIImage? {
        guard let decoder, isLoaded else { return nil }

        let options = DecodeOptions(targetSize: targetSize, cropRect: rect)
        guard let pixelBuffer = try? decoder.decode(options: options),
              let cgImage = pixelBuffer.makeCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Full Decode

    /// Decodes the full image at its original resolution.
    /// - Returns: The decoded image as a UIImage, or nil on failure.
    public func decodeFullImage() -> UIImage? {
        guard let decoder, isLoaded else { return nil }
        guard let pixelBuffer = try? decoder.decode(),
              let cgImage = pixelBuffer.makeCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Raw Decode Access

    /// Decodes the image with the given options and returns the raw pixel buffer.
    /// This is the lowest-level decode method, suitable for custom processing pipelines.
    /// - Parameter options: Controls target size, crop region, and pixel format.
    /// - Returns: A pixel buffer containing the decoded image data.
    /// - Throws: `ImageDecoderError` on failure.
    public func decode(options: DecodeOptions = DecodeOptions()) throws -> PixelBuffer {
        guard let decoder, isLoaded else {
            throw ImageDecoderError.invalidData
        }
        return try decoder.decode(options: options)
    }
}
