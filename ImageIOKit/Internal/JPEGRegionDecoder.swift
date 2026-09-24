//
//  JPEGRegionDecoder.swift
//  ImageIOKit
//
//  JPEG region decoder using TurboJPEG.
//  Supports partial decode via tj3SetCroppingRegion plus DCT scaling.
//

import Foundation
import CoreGraphics
import turbojpeg

struct JPEGRegionDecoder {

    private let imageData: Data
    private let imageWidth: Int
    private let imageHeight: Int

    private struct IntRect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    // MARK: - Init

    /// Creates a region decoder from in-memory JPEG data.
    /// - Parameter data: The compressed JPEG data.
    /// - Returns: `nil` if the JPEG header cannot be read.
    init?(data: Data) {
        self.imageData = data
        guard let (w, h) = JPEGRegionDecoder.readDimensions(data: data) else { return nil }
        self.imageWidth = w
        self.imageHeight = h
    }

    /// Creates a region decoder from a JPEG file on disk.
    /// - Parameter url: A local file URL to a JPEG file.
    /// - Returns: `nil` if the file cannot be read or the JPEG header is invalid.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    // MARK: - Header Reading

    private static func readDimensions(data: Data) -> (Int, Int)? {
        guard let handle = tj3Init(Int32(TJINIT_DECOMPRESS.rawValue)) else { return nil }
        defer { tj3Destroy(handle) }

        let headerStatus: Int32 = data.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return tj3DecompressHeader(handle, baseAddress, data.count)
        }
        guard headerStatus == 0 else { return nil }

        let width = Int(tj3Get(handle, Int32(TJPARAM_JPEGWIDTH.rawValue)))
        let height = Int(tj3Get(handle, Int32(TJPARAM_JPEGHEIGHT.rawValue)))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    // MARK: - Region Decode

    /// Decodes a specific region of the JPEG image.
    /// - Parameters:
    ///   - cropRect: The region to decode, in pixel coordinates of the full image.
    ///   - targetSize: Optional target size for the decoded region (enables DCT shrink-on-load).
    ///   - pixelFormat: The desired pixel format for the output.
    /// - Returns: A pixel buffer containing the decoded region.
    func decodeRegion(cropRect: CGRect, targetSize: CGSize? = nil,
                             pixelFormat: PixelBuffer.PixelFormat = .rgba8) throws -> PixelBuffer {
        guard pixelFormat == .rgba8 else {
            throw ImageDecoderError.unsupportedOperation
        }

        let clampedRect = try SoftwareScaler.clampedCrop(cropRect,
            in: CGSize(width: imageWidth, height: imageHeight))
        let outputSize = try SoftwareScaler.outputSize(for: clampedRect.size, fitting: targetSize)

        guard let handle = tj3Init(Int32(TJINIT_DECOMPRESS.rawValue)) else {
            throw ImageDecoderError.decodeFailed("Failed to initialize TurboJPEG decompressor")
        }
        defer { tj3Destroy(handle) }

        guard tj3Set(handle, Int32(TJPARAM_SAVEMARKERS.rawValue), 4) == 0 else {
            throw ImageDecoderError.decodeFailed(Self.lastTurboJPEGError(handle))
        }

        let headerStatus: Int32 = imageData.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return tj3DecompressHeader(handle, baseAddress, imageData.count)
        }
        guard headerStatus == 0 else {
            throw ImageDecoderError.invalidData
        }

        let colorSpace = try Self.readColorSpace(handle)

        let scaleFactor = JPEGRegionDecoder.bestScaleFactor(
            imageWidth: Int(clampedRect.width),
            imageHeight: Int(clampedRect.height),
            for: outputSize
        )
        guard tj3SetScalingFactor(handle, scaleFactor) == 0 else {
            throw ImageDecoderError.decodeFailed(Self.lastTurboJPEGError(handle))
        }

        let scaledImageWidth = JPEGRegionDecoder.scaledDimension(imageWidth, scaleFactor)
        let scaledImageHeight = JPEGRegionDecoder.scaledDimension(imageHeight, scaleFactor)
        let scaledCrop = JPEGRegionDecoder.scaledCropRect(
            clampedRect: clampedRect,
            scaledImageWidth: scaledImageWidth,
            scaledImageHeight: scaledImageHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        let subsamp = tj3Get(handle, Int32(TJPARAM_SUBSAMP.rawValue))
        let scaledMCUWidth = JPEGRegionDecoder.scaledDimension(
            JPEGRegionDecoder.mcuWidth(for: subsamp),
            scaleFactor
        )
        let alignedCropX = (scaledCrop.x / max(1, scaledMCUWidth)) * max(1, scaledMCUWidth)

        var decodeRect = IntRect(
            x: alignedCropX,
            y: scaledCrop.y,
            width: scaledCrop.x + scaledCrop.width - alignedCropX,
            height: scaledCrop.height
        )
        var postCropOffset = IntRect(x: scaledCrop.x - decodeRect.x, y: 0, width: scaledCrop.width, height: scaledCrop.height)

        let cropRegion = tjregion(
            x: Int32(decodeRect.x),
            y: Int32(decodeRect.y),
            w: Int32(decodeRect.width),
            h: Int32(decodeRect.height)
        )

        if tj3SetCroppingRegion(handle, cropRegion) != 0 {
            // If the JPEG stream doesn't support cropped decode, fall back to
            // full scaled decode and crop in memory.
            let uncropped = tjregion(x: 0, y: 0, w: 0, h: 0)
            guard tj3SetCroppingRegion(handle, uncropped) == 0 else {
                throw ImageDecoderError.decodeFailed(Self.lastTurboJPEGError(handle))
            }
            decodeRect = IntRect(x: 0, y: 0, width: scaledImageWidth, height: scaledImageHeight)
            postCropOffset = IntRect(x: scaledCrop.x, y: scaledCrop.y, width: scaledCrop.width, height: scaledCrop.height)
        }

        guard decodeRect.width > 0, decodeRect.height > 0 else {
            throw ImageDecoderError.decodeFailed("Computed crop decode size is empty")
        }

        let decodeBuffer = PixelBuffer(
            width: decodeRect.width,
            height: decodeRect.height,
            pixelFormat: .rgba8, colorSpace: colorSpace
        )
        let decodeStatus: Int32 = imageData.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return tj3Decompress8(
                handle,
                baseAddress,
                imageData.count,
                decodeBuffer.data.assumingMemoryBound(to: UInt8.self),
                Int32(decodeBuffer.bytesPerRow),
                Int32(TJPF_RGBA.rawValue)
            )
        }
        guard decodeStatus == 0 else {
            throw ImageDecoderError.decodeFailed(Self.lastTurboJPEGError(handle))
        }

        if postCropOffset.x == 0,
           postCropOffset.y == 0,
           postCropOffset.width == decodeRect.width,
           postCropOffset.height == decodeRect.height {
            return decodeBuffer
        }

        let finalBuffer = PixelBuffer(
            width: postCropOffset.width,
            height: postCropOffset.height,
            pixelFormat: .rgba8, colorSpace: colorSpace
        )
        let bytesPerPixel = 4

        for row in 0..<postCropOffset.height {
            let srcOffset = (row + postCropOffset.y) * decodeBuffer.bytesPerRow + postCropOffset.x * bytesPerPixel
            let dstOffset = row * finalBuffer.bytesPerRow
            memcpy(
                finalBuffer.data.advanced(by: dstOffset),
                decodeBuffer.data.advanced(by: srcOffset),
                postCropOffset.width * bytesPerPixel
            )
        }

        return finalBuffer
    }

    // MARK: - Helpers

    private static func bestScaleFactor(
        imageWidth: Int,
        imageHeight: Int,
        for targetSize: CGSize?
    ) -> tjscalingfactor {
        let unscaled = tjscalingfactor(num: 1, denom: 1)
        guard let targetSize else { return unscaled }

        var count: Int32 = 0
        guard let factors = tj3GetScalingFactors(&count), count > 0 else {
            return unscaled
        }

        let targetWidth = max(1, Int(targetSize.width.rounded(.up)))
        let targetHeight = max(1, Int(targetSize.height.rounded(.up)))
        var best = unscaled
        var bestArea = Int.max

        for index in 0..<Int(count) {
            let factor = factors[index]
            guard factor.num <= factor.denom else { continue }
            let scaledW = scaledDimension(imageWidth, factor)
            let scaledH = scaledDimension(imageHeight, factor)
            guard scaledW >= targetWidth, scaledH >= targetHeight else { continue }

            let area = scaledW * scaledH
            if area < bestArea {
                bestArea = area
                best = factor
            }
        }

        // Keep full-size decode if no downscale factor can satisfy target.
        if bestArea == Int.max {
            return unscaled
        }

        return best
    }

    private static func scaledDimension(_ value: Int, _ factor: tjscalingfactor) -> Int {
        (value * Int(factor.num) + Int(factor.denom) - 1) / Int(factor.denom)
    }

    private static func scaledCropRect(
        clampedRect: CGRect,
        scaledImageWidth: Int,
        scaledImageHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> IntRect {
        let scaleX = CGFloat(scaledImageWidth) / CGFloat(imageWidth)
        let scaleY = CGFloat(scaledImageHeight) / CGFloat(imageHeight)

        var minX = Int((clampedRect.minX * scaleX).rounded(.down))
        var minY = Int((clampedRect.minY * scaleY).rounded(.down))
        var maxX = Int((clampedRect.maxX * scaleX).rounded(.up))
        var maxY = Int((clampedRect.maxY * scaleY).rounded(.up))

        minX = max(0, min(minX, scaledImageWidth - 1))
        minY = max(0, min(minY, scaledImageHeight - 1))
        maxX = max(minX + 1, min(maxX, scaledImageWidth))
        maxY = max(minY + 1, min(maxY, scaledImageHeight))

        return IntRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func mcuWidth(for subsamp: Int32) -> Int {
        switch subsamp {
        case Int32(TJSAMP_422.rawValue), Int32(TJSAMP_420.rawValue):
            return 16
        case Int32(TJSAMP_411.rawValue):
            return 32
        default:
            return 8
        }
    }

    private static func lastTurboJPEGError(_ handle: tjhandle?) -> String {
        guard let message = tj3GetErrorStr(handle) else {
            return "TurboJPEG operation failed"
        }
        return String(cString: message)
    }

    private static func readColorSpace(_ handle: tjhandle) throws -> CGColorSpace {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        guard tj3GetICCProfile(handle, &bytes, &count) == 0 else {
            throw ImageDecoderError.decodeFailed(lastTurboJPEGError(handle))
        }
        guard let bytes else { return PixelBuffer.defaultColorSpace(for: .rgba8) }
        defer { tj3Free(bytes) }
        guard let space = CGColorSpace(iccData: Data(bytes: bytes, count: count) as CFData),
              space.model == .rgb else {
            // Let ImageIO handle profiles that do not describe TurboJPEG's RGB output.
            throw ImageDecoderError.unsupportedOperation
        }
        return space
    }
}
