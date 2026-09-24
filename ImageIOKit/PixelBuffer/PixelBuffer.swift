//
//  PixelBuffer.swift
//  ImageIOKit
//
//  Owns raw pixel data allocated by C codec libraries.
//  Converts to CGImage zero-copy via CGDataProvider.
//

import Foundation
import CoreGraphics

public final class PixelBuffer {

    /// The pixel data layout of the buffer. Alpha-bearing formats use premultiplied color.
    public enum PixelFormat {
        case rgba8    // 4 bytes per pixel, R-G-B-A order
        case rgb8     // 3 bytes per pixel, R-G-B order
        case gray8    // 1 byte per pixel, grayscale
        case grayAlpha8  // 2 bytes per pixel, gray + alpha

        public var bytesPerPixel: Int {
            switch self {
            case .rgba8: return 4
            case .rgb8: return 3
            case .gray8: return 1
            case .grayAlpha8: return 2
            }
        }

        public var hasAlpha: Bool {
            switch self {
            case .rgba8, .grayAlpha8: return true
            case .rgb8, .gray8: return false
            }
        }
    }

    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The number of bytes per row in the pixel data.
    public let bytesPerRow: Int

    /// The pixel format of the data.
    public let pixelFormat: PixelFormat

    /// The color space of the stored components. RGB buffers default to sRGB.
    public let colorSpace: CGColorSpace

    /// Raw pointer to the pixel data. Valid for the lifetime of this object.
    public let data: UnsafeMutableRawPointer

    /// The total size of the pixel data in bytes.
    public var dataSize: Int { bytesPerRow * height }

    // Closure that frees the pixel data when this buffer is deallocated.
    // Each codec library has its own free function (tjFree, WebPFree, etc.).
    private let deallocator: (UnsafeMutableRawPointer) -> Void

    /// Creates a pixel buffer wrapping existing C-allocated memory.
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bytesPerRow: Stride of each row in bytes.
    ///   - pixelFormat: The layout of pixel components.
    ///   - data: Pointer to C-allocated pixel memory. Ownership transfers to this buffer.
    ///   - colorSpace: The color space matching the stored components.
    ///   - deallocator: Called on deinit. Defaults to Swift pointer `deallocate()`.
    public init(width: Int, height: Int, bytesPerRow: Int, pixelFormat: PixelFormat,
                data: UnsafeMutableRawPointer, colorSpace: CGColorSpace? = nil,
                deallocator: @escaping (UnsafeMutableRawPointer) -> Void = { $0.deallocate() }) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace ?? Self.defaultColorSpace(for: pixelFormat)
        self.data = data
        self.deallocator = deallocator
    }

    /// Creates a pixel buffer by allocating new zero-initialized memory.
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - pixelFormat: The layout of pixel components.
    public convenience init(width: Int, height: Int, pixelFormat: PixelFormat, colorSpace: CGColorSpace? = nil) {
        let bytesPerRow = width * pixelFormat.bytesPerPixel
        let size = bytesPerRow * height
        let data = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        self.init(width: width, height: height, bytesPerRow: bytesPerRow,
                  pixelFormat: pixelFormat, data: data, colorSpace: colorSpace)
    }

    static func defaultColorSpace(for format: PixelFormat) -> CGColorSpace {
        switch format {
        case .rgba8, .rgb8: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .gray8, .grayAlpha8: return CGColorSpaceCreateDeviceGray()
        }
    }

    deinit {
        deallocator(data)
    }
}

// MARK: - CGImage Conversion

extension PixelBuffer {

    /// Creates a CGImage backed by this pixel buffer's data.
    /// The pixel buffer is retained for the lifetime of the CGImage (zero-copy).
    public func makeCGImage() -> CGImage? {
        let bitsPerComponent = 8
        let bitsPerPixel = pixelFormat.bytesPerPixel * 8

        let bitmapInfo: CGBitmapInfo

        switch pixelFormat {
        case .rgba8:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        case .rgb8:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case .gray8:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case .grayAlpha8:
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        // Retain self to keep the pixel data alive for the CGImage's lifetime
        let retained = Unmanaged.passRetained(self)

        guard let provider = CGDataProvider(
            dataInfo: retained.toOpaque(),
            data: data,
            size: dataSize,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<PixelBuffer>.fromOpaque(info).release()
            }
        ) else {
            retained.release()
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Pixel Access

extension PixelBuffer {

    /// Returns the pixel value at the given coordinates as RGBA components.
    /// For non-RGBA formats, missing components default to 0 (alpha defaults to 255).
    /// - Parameters:
    ///   - x: The horizontal pixel coordinate (0-based, left to right).
    ///   - y: The vertical pixel coordinate (0-based, top to bottom).
    /// - Returns: The RGBA components, or `(0, 0, 0, 0)` if out of bounds.
    public func pixel(at x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0, 0) }
        let offset = y * bytesPerRow + x * pixelFormat.bytesPerPixel
        let ptr = data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

        switch pixelFormat {
        case .rgba8:
            return (ptr[0], ptr[1], ptr[2], ptr[3])
        case .rgb8:
            return (ptr[0], ptr[1], ptr[2], 255)
        case .gray8:
            let v = ptr[0]
            return (v, v, v, 255)
        case .grayAlpha8:
            let v = ptr[0]
            return (v, v, v, ptr[1])
        }
    }
}
