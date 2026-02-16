//
//  SoftwareScaler.swift
//  ImageIOKit
//
//  vImage-based fallback for formats that lack native shrink/crop support.
//  Used by PNG, AVIF, and JXL decoders, and as a post-processing step
//  when native capabilities don't fully satisfy the decode options.
//

import Foundation
import CoreGraphics
import Accelerate

public enum SoftwareScaler {

    /// Scales a pixel buffer to the target size using vImage's high-quality Lanczos resampling.
    public static func scale(_ source: PixelBuffer, to targetSize: CGSize) -> PixelBuffer? {
        let targetWidth = Int(targetSize.width)
        let targetHeight = Int(targetSize.height)
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        if targetWidth == source.width && targetHeight == source.height { return source }

        var srcBuffer = vImage_Buffer(
            data: source.data,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width),
            rowBytes: source.bytesPerRow
        )

        let destBytesPerRow = targetWidth * source.pixelFormat.bytesPerPixel
        let dest = PixelBuffer(width: targetWidth, height: targetHeight, pixelFormat: source.pixelFormat)

        var dstBuffer = vImage_Buffer(
            data: dest.data,
            height: vImagePixelCount(targetHeight),
            width: vImagePixelCount(targetWidth),
            rowBytes: destBytesPerRow
        )

        let error: vImage_Error
        switch source.pixelFormat {
        case .rgba8:
            error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        case .rgb8:
            // vImage doesn't have a direct 3-channel scaler; promote to ARGB, scale, demote
            return scaleViaARGB(source, to: targetSize)
        case .gray8:
            error = vImageScale_Planar8(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        case .grayAlpha8:
            // Treat as 2-channel interleaved; use the ARGB scaler on padded data
            return scaleViaARGB(source, to: targetSize)
        }

        guard error == kvImageNoError else { return nil }
        return dest
    }

    /// Crops a pixel buffer to the given rect (in pixel coordinates of the source).
    public static func crop(_ source: PixelBuffer, to rect: CGRect) -> PixelBuffer? {
        let x = Int(rect.origin.x)
        let y = Int(rect.origin.y)
        let cropWidth = Int(rect.width)
        let cropHeight = Int(rect.height)

        guard x >= 0, y >= 0, cropWidth > 0, cropHeight > 0,
              x + cropWidth <= source.width, y + cropHeight <= source.height else { return nil }

        let bpp = source.pixelFormat.bytesPerPixel
        let destBytesPerRow = cropWidth * bpp
        let dest = PixelBuffer(width: cropWidth, height: cropHeight, pixelFormat: source.pixelFormat)

        for row in 0..<cropHeight {
            let srcOffset = (y + row) * source.bytesPerRow + x * bpp
            let dstOffset = row * destBytesPerRow
            memcpy(dest.data.advanced(by: dstOffset),
                   source.data.advanced(by: srcOffset),
                   destBytesPerRow)
        }
        return dest
    }

    /// Crops then scales a pixel buffer.
    public static func cropAndScale(_ source: PixelBuffer, cropRect: CGRect, targetSize: CGSize) -> PixelBuffer? {
        guard let cropped = crop(source, to: cropRect) else { return nil }
        return scale(cropped, to: targetSize)
    }

    /// Computes the best fitting size that preserves aspect ratio within a bounding box.
    public static func fittingSize(for imageSize: CGSize, in boundingSize: CGSize) -> CGSize {
        let scale = min(boundingSize.width / imageSize.width,
                        boundingSize.height / imageSize.height)
        return CGSize(width: (imageSize.width * scale).rounded(.down),
                      height: (imageSize.height * scale).rounded(.down))
    }
}

// MARK: - Helpers

extension SoftwareScaler {

    /// Scale non-ARGB formats by temporarily promoting to ARGB8888.
    private static func scaleViaARGB(_ source: PixelBuffer, to targetSize: CGSize) -> PixelBuffer? {
        // Render the source into an RGBA8 buffer via CGImage round-trip
        guard let cgImage = source.makeCGImage() else { return nil }

        let targetWidth = Int(targetSize.width)
        let targetHeight = Int(targetSize.height)
        let destBytesPerRow = targetWidth * 4

        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: destBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let outputImage = ctx.makeImage(),
              let outputData = outputImage.dataProvider?.data as Data? else { return nil }

        let dest = PixelBuffer(width: targetWidth, height: targetHeight, pixelFormat: .rgba8)
        outputData.withUnsafeBytes { srcPtr in
            if let baseAddress = srcPtr.baseAddress {
                memcpy(dest.data, baseAddress, min(outputData.count, dest.dataSize))
            }
        }
        return dest
    }
}
