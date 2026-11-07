//
//  ImageSource+Texture.swift
//  ImageIOKit
//
//  Decodes straight to a Metal texture, leaving the final resample to the GPU.
//  Codecs stop at their nearest native reduced size; MPS Lanczos finishes the fit.
//

import Foundation
import CoreGraphics
import ImageIO
import Metal
import MetalPerformanceShaders

/// Reusable GPU state for `ImageSource.makeTexture(fitting:pixelFormat:using:)`.
/// Create one per device for the lifetime of the reader and share it between tasks.
public final class TextureScaler: @unchecked Sendable {

    /// The device that owns every texture this scaler produces.
    public let device: MTLDevice

    private let queue: MTLCommandQueue
    private let lanczos: MPSImageLanczosScale
    // MPS kernels must not be encoded from several threads at once. Encoding takes
    // microseconds, so a lock costs nothing next to decoding.
    private let lock = NSLock()

    /// Returns `nil` if the device does not support Metal Performance Shaders.
    public init?(device: MTLDevice) {
        guard MPSSupportsMTLDevice(device), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.lanczos = MPSImageLanczosScale(device: device)
        // The default .zero edge mode blends transparent black into border pixels.
        self.lanczos.edgeMode = .clamp
    }

    /// Lanczos-resamples `source` into a new private texture of `size` and waits for the GPU.
    func scale(_ source: MTLTexture, to size: CGSize) async throws -> MTLTexture {
        let (destination, commandBuffer) = try makeDestination(like: source, size: size, usage: [.shaderRead, .shaderWrite])
        lock.withLock {
            lanczos.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
        }
        try await complete(commandBuffer)
        return destination
    }

    /// Copies an already-fitted texture into private storage, the GPU's preferred layout.
    func copyToPrivate(_ source: MTLTexture) async throws -> MTLTexture {
        let size = CGSize(width: source.width, height: source.height)
        let (destination, commandBuffer) = try makeDestination(like: source, size: size, usage: .shaderRead)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ImageDecoderError.decodeFailed("Failed to encode texture copy")
        }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
        try await complete(commandBuffer)
        return destination
    }

    private func makeDestination(like source: MTLTexture, size: CGSize,
                                 usage: MTLTextureUsage) throws -> (MTLTexture, MTLCommandBuffer) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let destination = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw ImageDecoderError.decodeFailed("Failed to allocate GPU resampling resources")
        }
        return (destination, commandBuffer)
    }

    /// Commits `commandBuffer` and waits for the GPU without blocking a thread.
    private func complete(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { buffer in
                if buffer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: buffer.error
                        ?? ImageDecoderError.decodeFailed("GPU resampling did not complete"))
                }
            }
            commandBuffer.commit()
        }
    }
}

extension ImageSource {

    /// Decodes a texture fitting `targetSize`, preserving aspect ratio and never upscaling.
    ///
    /// Codecs decode to their nearest reduced size at or above the fit (ImageIO JPEG subsampling,
    /// TurboJPEG DCT scaling on Mac, JPEG XL DC or box-filtered output). The GPU then performs a
    /// single Lanczos resample. WebP, which libwebp scales exactly, needs no GPU pass. Other
    /// formats and rotated JPEGs use `decode(targetSize:pixelFormat:)`.
    ///
    /// - Parameters:
    ///   - targetSize: Bounding box for the texture, in pixels.
    ///   - pixelFormat: `.rgba8` produces `rgba8Unorm` with premultiplied sRGB components;
    ///     `.gray8` produces `r8Unorm`. Other formats throw `invalidOptions`.
    ///   - scaler: Shared GPU state; textures are created on its device.
    /// - Returns: A private-storage texture readable by shaders once this returns.
    public func makeTexture(fitting targetSize: CGSize, pixelFormat: PixelBuffer.PixelFormat = .rgba8,
                            using scaler: TextureScaler) async throws -> MTLTexture {
        guard isLoaded else { throw ImageDecoderError.invalidData }
        guard pixelFormat == .rgba8 || pixelFormat == .gray8 else {
            throw ImageDecoderError.invalidOptions("Textures support rgba8 and gray8 output")
        }
        let size = try SoftwareScaler.outputSize(for: imageSize, fitting: targetSize)
        // Decoders write straight into shared GPU memory, which a linear texture then wraps,
        // so pixels are never copied for upload.
        let buffer = try PixelBuffer.withMetalStorage(on: scaler.device) {
            try nativeTextureSource(covering: size, targetSize: targetSize, pixelFormat: pixelFormat)
                ?? decode(targetSize: targetSize, pixelFormat: pixelFormat)
        }
        guard let source = buffer.makeTextureSharingStorage(device: scaler.device)
                ?? buffer.makeTexture(device: scaler.device) else {
            throw ImageDecoderError.decodeFailed("Failed to create texture")
        }
        if source.width == Int(size.width), source.height == Int(size.height) {
            return try await scaler.copyToPrivate(source)
        }
        return try await scaler.scale(source, to: size)
    }
}

extension ImageSource {

    /// Source-native pixels at or above `size` in `pixelFormat` and its default color space,
    /// or `nil` when the format has no reduced-size decode worth uploading.
    func nativeTextureSource(covering size: CGSize, targetSize: CGSize,
                             pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer? {
        switch fileFormat {
        case .webp:
            // libwebp scales exactly, so the result only needs the usual finishing.
            return try nativeWebP(targetSize: targetSize).map { try finish($0, size: size, pixelFormat: pixelFormat) }
        case .jpegXL:
            let decoder = url.flatMap { JXLDecoder(url: $0) } ?? data.flatMap { JXLDecoder(data: $0) }
            guard let buffer = try? decoder?.decodeThumbnail(fittingSize: size,
                                                              prefersGrayscale: pixelFormat == .gray8) else { return nil }
            return try converted(buffer, to: pixelFormat)
        case .jpeg:
            guard orientation == .up else { return nil }
            if let buffer = turboJPEGTextureSource(covering: size, pixelFormat: pixelFormat) { return buffer }
            // Factor 1 allows a full decode for reductions under 2x; the GPU still does the fit.
            guard let image = imageIOSubsampledImage(covering: size, factors: [8, 4, 2, 1]) else { return nil }
            return try render(image, size: CGSize(width: image.width, height: image.height), pixelFormat: pixelFormat)
        default:
            return nil
        }
    }

    /// Converts color space or layout on the CPU at native size only when needed, so the GPU
    /// resample always receives components in the output's default color space.
    func converted(_ buffer: PixelBuffer, to pixelFormat: PixelBuffer.PixelFormat) throws -> PixelBuffer {
        if buffer.pixelFormat == pixelFormat, buffer.colorSpace == PixelBuffer.defaultColorSpace(for: pixelFormat) {
            return buffer
        }
        guard let image = buffer.makeCGImage() else {
            throw ImageDecoderError.decodeFailed("Failed to create image from decoded pixels")
        }
        return try render(image, size: CGSize(width: buffer.width, height: buffer.height), pixelFormat: pixelFormat)
    }

    /// On Apple Silicon, ImageIO's hardware JPEG decode beat TurboJPEG's DCT-scaled decode in
    /// every cell of the M1 Air sweep (6.6-50 MP, colour and gray, 1.5-9x), idle and under full
    /// CPU contention, which the fixed-function decoder barely notices. That matches every iOS
    /// device, so arm64 always uses ImageIO; the M4 Max's small win below 7 MP (2026-11-06) is
    /// forgone for robustness on the floor. Intel Macs have no hardware decoder and keep the
    /// provisional 12 MP cutoff, unmeasured on real hardware
    /// (docs/benchmarks/2026-11-07-turbojpeg-cutoff-m1.md).
    func turboJPEGTextureSource(covering size: CGSize, pixelFormat: PixelBuffer.PixelFormat) -> PixelBuffer? {
        #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
        guard imageSize.width * imageSize.height <= 12_000_000 else { return nil }
        let decoder = url.flatMap { JPEGRegionDecoder(url: $0) } ?? data.flatMap { JPEGRegionDecoder(data: $0) }
        // Gray pages decode straight to one channel; RGBA requests expand them during conversion.
        // Unsupported profiles and color JPEGs requested as gray throw here and fall back to ImageIO.
        let decodeFormat: PixelBuffer.PixelFormat = colorModel == .grayscale ? .gray8 : .rgba8
        guard decodeFormat == pixelFormat || decodeFormat == .gray8,
              let buffer = try? decoder?.decodeRegion(cropRect: CGRect(origin: .zero, size: imageSize),
                                                      targetSize: size, pixelFormat: decodeFormat) else { return nil }
        return try? converted(buffer, to: pixelFormat)
        #else
        return nil
        #endif
    }
}
