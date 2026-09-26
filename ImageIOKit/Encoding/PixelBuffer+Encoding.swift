import Foundation
import CoreGraphics
import ImageIO
import Darwin

public extension PixelBuffer {
    /// Encodes these pixels to a file without decoding the original image again.
    ///
    /// Retains the buffer's color profile. PNG preserves alpha; JPEG composites over black.
    /// The parent directory must exist. A completed sibling temporary file atomically replaces
    /// the destination, so a failed encode leaves an existing cache entry intact.
    /// This method is synchronous; callers choose its queue and must not mutate the pixels
    /// until it returns. Supported encoders depend on ImageIO on the current OS.
    /// - Parameters:
    ///   - quality: Finite compression quality, clamped to 0...1. Defaults to 0.95.
    ///              Ignored by lossless formats.
    func write(to url: URL, as format: ImageFileFormat, quality: Double = 0.95) throws {
        guard url.isFileURL, quality.isFinite else {
            throw ImageEncoderError.encodeFailed("Writing pixels requires a file URL and finite quality")
        }
        guard var image = makeCGImage() else {
            throw ImageEncoderError.encodeFailed("Failed to create an image from the pixel buffer")
        }
        if format.isOpaque && pixelFormat.hasAlpha {
            // Preserve the source profile while compositing premultiplied pixels over black.
            let alpha: CGImageAlphaInfo = colorSpace.model == .monochrome ? .none : .noneSkipLast
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: colorSpace, bitmapInfo: alpha.rawValue) else {
                throw ImageEncoderError.encodeFailed("Failed to allocate opaque encoding pixels")
            }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let opaque = context.makeImage() else {
                throw ImageEncoderError.encodeFailed("Failed to composite encoding pixels")
            }
            image = opaque
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".imageiokit-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                format.uniformTypeIdentifier, 1, nil) else {
            throw ImageEncoderError.encodeFailed("Failed to create encoder for \(format)")
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncoderError.encodeFailed("Failed to finalize encoded pixels")
        }
        let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            url.withUnsafeFileSystemRepresentation { destinationPath in
                rename(temporaryPath!, destinationPath!)
            }
        }
        guard result == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw ImageEncoderError.encodeFailed("Failed to replace cache file: \(error.localizedDescription)")
        }
    }
}
