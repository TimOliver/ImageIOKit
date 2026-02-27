//
//  PixelBuffer+Metal.swift
//  ImageIOKit
//
//  Metal texture creation from raw pixel buffers.
//  Uses .shared storage for zero-bus-transfer on Apple Silicon unified memory.
//

import Metal

extension PixelBuffer.PixelFormat {

    /// The Metal pixel format matching this buffer's layout.
    /// Returns `nil` for `rgb8` — Metal has no 3-byte format.
    public var metalPixelFormat: MTLPixelFormat? {
        switch self {
        case .rgba8:      .rgba8Unorm
        case .gray8:      .r8Unorm
        case .grayAlpha8: .rg8Unorm
        case .rgb8:       nil
        }
    }
}

extension PixelBuffer {

    /// Creates a Metal texture and copies this buffer's pixel data into it.
    ///
    /// The copy is immediate — the buffer can be released after this returns.
    /// Uses `.shared` storage (CPU + GPU visible), which is optimal on
    /// Apple Silicon's unified memory.
    ///
    /// Returns `nil` if the pixel format has no Metal equivalent (i.e. `rgb8`)
    /// or if texture allocation fails.
    public func makeTexture(device: MTLDevice,
                            usage: MTLTextureUsage = .shaderRead) -> MTLTexture? {
        guard let format = pixelFormat.metalPixelFormat else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return texture
    }
}
