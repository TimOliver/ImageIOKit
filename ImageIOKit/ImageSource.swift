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
    /// - **PNG/WebP/HEIC/AVIF**: ~1.5x — moderate decompression overhead
    /// - **JXL**: ~4x — VarDCT requires float32 working buffers
    ///
    /// Use this to decide whether to decode images concurrently or serially
    /// (e.g. compare against `os_proc_available_memory()`).
    public var estimatedDecodeMemory: Int {
        let bitmapBytes = Int(imageSize.width) * Int(imageSize.height) * 4
        let multiplier: Double = switch fileFormat {
        case .jpeg:   0.5
        case .jpegXL: 4.0
        default:      1.5
        }
        return Int(Double(bitmapBytes) * multiplier)
    }

    // MARK: - Private Properties

    /// The underlying CGImageSource.
    private var cgImageSource: CGImageSource?

    /// Cached full-resolution CGImage. Statically defined so NSCache can
    /// manage it and purge under memory pressure. Shared across
    /// all threads
    private static let fullDecodeCacheKey = "fullDecode" as NSString
    private let fullDecodeCache: NSCache<NSString, CGImage> = {
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

    // MARK: - Thumbnail Generation

    /// Generates a downscaled copy of the original image, optimistically avoiding decoding
    /// the whole original image into memory if possible.
    /// - Parameter size: The preferred bounding size that the thumbnail will scale to fit in.
    /// - Returns: The downscaled image if successful, nil otherwise.
    public func makeThumbnail(fittingSize size: CGSize) -> UIImage? {
        guard isLoaded else { return nil }

        // JXL: decode via libjxl callback decoder for lower peak memory,
        // then scale down to the requested thumbnail size.
        if fileFormat == .jpegXL {
            if let thumbnail = makeJXLThumbnail(fittingSize: size) {
                return thumbnail
            }
        }

        guard let cgImageSource else { return nil }

        let maxDimension = max(size.width, size.height)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Decodes a JXL image via libjxl's DC-only progressive decode and scales
    /// it down to fit within the given bounding size.
    ///
    /// For VarDCT images, only the DC coefficients (1/8th resolution) are decoded,
    /// saving ~98% of decode memory. The small result is then scaled to the exact
    /// target size via CGContext.
    private func makeJXLThumbnail(fittingSize size: CGSize) -> UIImage? {
        let decoder: JXLDecoder?
        if let url {
            decoder = JXLDecoder(url: url)
        } else if let data {
            decoder = JXLDecoder(data: data)
        } else {
            return nil
        }

        guard let decoder,
              let pixelBuffer = try? decoder.decodeThumbnail(fittingSize: size),
              let dcImage = pixelBuffer.makeCGImage() else {
            return nil
        }

        // Compute the scaled size that fits within the bounding box
        let imageWidth = CGFloat(pixelBuffer.width)
        let imageHeight = CGFloat(pixelBuffer.height)
        let scale = min(size.width / imageWidth, size.height / imageHeight)
        // If the DC image already fits, return it directly
        if scale >= 1.0 {
            return UIImage(cgImage: dcImage)
        }

        let targetWidth = Int((imageWidth * scale).rounded())
        let targetHeight = Int((imageHeight * scale).rounded())

        // Scale via CGContext
        guard let colorSpace = dcImage.colorSpace,
              let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(dcImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = ctx.makeImage() else { return nil }
        return UIImage(cgImage: scaled)
    }

    // MARK: - Region Decode

    /// Decodes a specific region of the image, using native region decode when available.
    /// - Parameter rect: The region to decode, in pixel coordinates of the full image.
    /// - Parameter targetSize: Optional target size for the decoded region.
    /// - Returns: The decoded region as a UIImage, or nil on failure.
    public func decodeRegion(_ rect: CGRect, targetSize: CGSize? = nil) -> UIImage? {
        guard isLoaded else { return nil }

        // JPEG: use libjpeg native region decode
        if fileFormat == .jpeg {
            let regionDecoder: JPEGRegionDecoder?
            if let url {
                regionDecoder = JPEGRegionDecoder(url: url)
            } else if let data {
                regionDecoder = JPEGRegionDecoder(data: data)
            } else {
                return nil
            }

            guard let regionDecoder,
                  let pixelBuffer = try? regionDecoder.decodeRegion(cropRect: rect, targetSize: targetSize),
                  let cgImage = pixelBuffer.makeCGImage() else { return nil }
            return UIImage(cgImage: cgImage)
        }

        // All other formats: full decode via ImageIO + CGImage.cropping
        guard let fullImage = decodeFullCGImage() else { return nil }

        // Clamp the rect to the image bounds
        let clampedRect = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clampedRect.isEmpty,
              let cropped = fullImage.cropping(to: clampedRect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    // MARK: - Full Decode

    /// Decodes the full image at its original resolution.
    /// - Returns: The decoded image as a UIImage, or nil on failure.
    public func decodeFullImage() -> UIImage? {
        guard let cgImage = decodeFullCGImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Decodes the full image and returns a CGImage. The result is cached so
    /// that repeated calls (e.g. tiling multiple regions) reuse the same decode.
    /// The cache is purgeable under memory pressure.
    public func decodeFullCGImage() -> CGImage? {
        if let cached = fullDecodeCache.object(forKey: ImageSource.fullDecodeCacheKey) {
            return cached
        }

        guard let cgImageSource, isLoaded else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(cgImageSource, 0, options as CFDictionary) else {
            return nil
        }
        fullDecodeCache.setObject(image, forKey: ImageSource.fullDecodeCacheKey)
        return image
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

    // MARK: - Raw Decode Access

    /// Decodes the image and returns the raw pixel buffer.
    /// This is the lowest-level decode method, suitable for custom processing pipelines.
    /// - Parameters:
    ///   - targetSize: Target output size. The decoder will produce an image close to this
    ///     size using the most efficient method available. Pass `nil` for full-resolution decode.
    ///   - cropRect: Region of the full image to decode, in pixel coordinates.
    ///     For JPEG sources, this uses native region decode (libjpeg crop_scanline).
    ///     For others, the full image is decoded then cropped. Pass `nil` to decode the entire image.
    ///   - pixelFormat: Desired pixel format for the output buffer.
    /// - Returns: A pixel buffer containing the decoded image data.
    /// - Throws: `ImageDecoderError` on failure.
    public func decode(
        targetSize: CGSize? = nil,
        cropRect: CGRect? = nil,
        pixelFormat: PixelBuffer.PixelFormat = .rgba8
    ) throws -> PixelBuffer {
        guard let cgImageSource, isLoaded else {
            throw ImageDecoderError.invalidData
        }

        // Determine the CGImage to work with
        let cgImage: CGImage

        if let targetSize, cropRect == nil {
            // Use thumbnailing for downscaled decode
            let maxDimension = max(targetSize.width, targetSize.height)
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(cgImageSource, 0, thumbOptions as CFDictionary) else {
                throw ImageDecoderError.decodeFailed("CGImageSourceCreateThumbnailAtIndex failed")
            }
            cgImage = thumb
        } else {
            // Full decode
            let fullOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let full = CGImageSourceCreateImageAtIndex(cgImageSource, 0, fullOptions as CFDictionary) else {
                throw ImageDecoderError.decodeFailed("CGImageSourceCreateImageAtIndex failed")
            }
            cgImage = full
        }

        // Apply crop if requested
        var workingImage = cgImage
        if let cropRect {
            guard let cropped = cgImage.cropping(to: cropRect) else {
                throw ImageDecoderError.invalidOptions("Crop rect \(cropRect) is out of bounds")
            }
            workingImage = cropped

            // If target size was also requested, scale via a second thumbnail pass
            if let targetSize {
                let fitSize = SoftwareScaler.fittingSize(
                    for: CGSize(width: workingImage.width, height: workingImage.height),
                    in: targetSize
                )
                workingImage = try renderToSize(workingImage, size: fitSize)
            }
        }

        // Render CGImage into a PixelBuffer
        return try renderToPixelBuffer(workingImage, pixelFormat: pixelFormat)
    }

    // MARK: - Private Helpers

    /// Renders a CGImage into a new CGImage at the specified size.
    private func renderToSize(_ image: CGImage, size: CGSize) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else {
            throw ImageDecoderError.invalidOptions("Target size is zero")
        }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else {
            throw ImageDecoderError.decodeFailed("Failed to create CGContext for scaling")
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let result = ctx.makeImage() else {
            throw ImageDecoderError.decodeFailed("Failed to create scaled CGImage")
        }
        return result
    }

    /// Renders a CGImage into a PixelBuffer with the requested pixel format.
    private func renderToPixelBuffer(_ image: CGImage, pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        let width = image.width
        let height = image.height
        let buffer = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
        let drawRect = CGRect(x: 0, y: 0, width: width, height: height)

        // CGContext at 8bpc only supports gray/1-byte and RGBA/RGBX/4-byte.
        // For rgb8 and grayAlpha8 we render to a supported intermediate and convert.
        switch pixelFormat {
        case .gray8:
            guard let ctx = CGContext(
                data: buffer.data, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

        case .rgba8:
            guard let ctx = CGContext(
                data: buffer.data, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

        case .rgb8:
            // Render to RGBX (4 bytes/pixel), then strip the padding byte
            let tempBytesPerRow = width * 4
            let tempData = UnsafeMutableRawPointer.allocate(byteCount: tempBytesPerRow * height, alignment: 16)
            defer { tempData.deallocate() }

            guard let ctx = CGContext(
                data: tempData, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: tempBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

            let src = tempData.assumingMemoryBound(to: UInt8.self)
            let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let s = row * tempBytesPerRow + col * 4
                    let d = row * buffer.bytesPerRow + col * 3
                    dst[d] = src[s]; dst[d+1] = src[s+1]; dst[d+2] = src[s+2]
                }
            }

        case .grayAlpha8:
            // Render to RGBA (4 bytes/pixel), then convert to luminance + alpha
            let tempBytesPerRow = width * 4
            let tempData = UnsafeMutableRawPointer.allocate(byteCount: tempBytesPerRow * height, alignment: 16)
            defer { tempData.deallocate() }

            guard let ctx = CGContext(
                data: tempData, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: tempBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ImageDecoderError.decodeFailed("Failed to create CGContext for pixel buffer rendering") }
            ctx.draw(image, in: drawRect)

            let src = tempData.assumingMemoryBound(to: UInt8.self)
            let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let s = row * tempBytesPerRow + col * 4
                    let d = row * buffer.bytesPerRow + col * 2
                    let gray = (299 * Int(src[s]) + 587 * Int(src[s+1]) + 114 * Int(src[s+2])) / 1000
                    dst[d] = UInt8(gray); dst[d+1] = src[s+3]
                }
            }
        }

        return buffer
    }
}

// MARK: - ImageSource condition / transcode

public extension ImageSource {

    /// Produces a JPEG file optimized for efficient partial decoding.
    ///
    /// - If the source is already JPEG and fits within `maxDimension`, returns
    ///   the original source unchanged (no work done).
    /// - For JXL-from-JPEG sources that fit within `maxDimension`, writes the
    ///   losslessly reconstructed JPEG to `url` (zero quality loss).
    /// - Otherwise, decodes at a resolution capped to `maxDimension`
    ///   (preserving aspect ratio), encodes as JPEG, and writes to `url`.
    ///
    /// The caller decides where to write and when to clean up.
    ///
    /// - Parameters:
    ///   - maxDimension: The maximum allowed length of the image's longest edge in pixels.
    ///                   Images larger than this are downscaled (preserving aspect ratio)
    ///                   before encoding. Defaults to 4096.
    ///   - url: The file URL to write the conditioned JPEG to.
    ///   - encodeOptions: Options for JPEG encoding (quality). Defaults to standard quality.
    func condition(maxDimension: Int = 4096,
                   to url: URL,
                   encodeOptions: EncodeOptions = EncodeOptions()) throws -> ImageSource {
        let maxDim = CGFloat(maxDimension)
        let longEdge = max(imageSize.width, imageSize.height)

        // Fast path: already JPEG and fits — no work needed
        if fileFormat == .jpeg && longEdge <= maxDim {
            return self
        }

        // JXL → lossless JPEG reconstruction avoids the expensive full JXL decode.
        // If the reconstructed JPEG is oversized, thumbnail it via ImageIO.
        if fileFormat == .jpegXL, let jpegData = reconstructJPEG() {
            if longEdge <= maxDim {
                // Fits — write reconstructed JPEG directly
                try jpegData.write(to: url)
                guard let conditioned = ImageSource(url: url) else {
                    throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG from JXL reconstruction")
                }
                return conditioned
            }

            // Oversized — thumbnail the reconstructed JPEG via ImageIO
            guard let jpegSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
                throw ImageEncoderError.encodeFailed("Failed to create CGImageSource from reconstructed JPEG")
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(jpegSource, 0, thumbOptions as CFDictionary) else {
                throw ImageEncoderError.encodeFailed("Failed to create thumbnail from reconstructed JPEG")
            }
            try thumb.write(to: url, as: .jpeg, options: encodeOptions)
            guard let conditioned = ImageSource(url: url) else {
                throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
            }
            return conditioned
        }

        // General path: thumbnail via ImageIO (capped to maxDimension), encode as JPEG
        guard let cgSource = CGImageSourceCreateWithURL((self.url ?? url) as CFURL, nil)
                ?? (data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }) else {
            throw ImageEncoderError.encodeFailed("Failed to create CGImageSource for conditioning")
        }

        let cgImage: CGImage
        if longEdge > maxDim {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, thumbOptions as CFDictionary) else {
                throw ImageEncoderError.encodeFailed("Failed to create thumbnail for conditioning")
            }
            cgImage = thumb
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else {
                throw ImageEncoderError.encodeFailed("Failed to decode image for conditioning")
            }
            cgImage = full
        }

        try cgImage.write(to: url, as: .jpeg, options: encodeOptions)

        guard let conditioned = ImageSource(url: url) else {
            throw ImageEncoderError.encodeFailed("Failed to load conditioned JPEG")
        }
        return conditioned
    }

    /// Decode from this image source and re-encode to a target format (convenience transcode).
    ///
    /// When transcoding JXL → JPEG, this automatically attempts JPEG bitstream
    /// reconstruction first. If the JXL was created from a JPEG, the exact original
    /// JPEG is returned with zero quality loss and no decode/re-encode overhead.
    ///
    /// - Parameters:
    ///   - format: The target image file format.
    ///   - encodeOptions: Options for encoding to the target format.
    /// - Returns: The transcoded image data.
    func transcode(to format: ImageFileFormat,
                   encodeOptions: EncodeOptions = EncodeOptions()) throws -> Data {
        // Fast path: JXL → JPEG via lossless bitstream reconstruction
        if format == .jpeg, fileFormat == .jpegXL,
           let jpegData = reconstructJPEG() {
            return jpegData
        }

        guard let cgImage = decodeFullCGImage() else {
            throw ImageEncoderError.encodeFailed("Failed to decode source image for transcoding")
        }
        return try cgImage.encode(as: format, options: encodeOptions)
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
