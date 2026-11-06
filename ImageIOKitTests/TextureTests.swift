//
//  TextureTests.swift
//  ImageIOKitTests
//
//  Tests for ImageSource.makeTexture(fitting:pixelFormat:using:), which resamples on the GPU.
//

import XCTest
import Metal
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

final class TextureTests: XCTestCase {

    private func makeScaler() throws -> TextureScaler {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is unavailable")
        return try XCTUnwrap(TextureScaler(device: device))
    }

    /// Copies a texture's pixels to the CPU, blitting private textures through a shared one.
    private func readBack(_ texture: MTLTexture, scaler: TextureScaler) throws -> [UInt8] {
        let bytesPerPixel = texture.pixelFormat == .r8Unorm ? 1 : 4
        var readable = texture
        if texture.storageMode == .private {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            descriptor.storageMode = .shared
            readable = try XCTUnwrap(scaler.device.makeTexture(descriptor: descriptor))
            let queue = try XCTUnwrap(scaler.device.makeCommandQueue())
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
            blit.copy(from: texture, to: readable)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * bytesPerPixel)
        bytes.withUnsafeMutableBytes {
            readable.getBytes($0.baseAddress!, bytesPerRow: texture.width * bytesPerPixel,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    // A 16x JPEG reduction goes through a subsampled decode and a GPU Lanczos pass.
    // 1 px stripes must average to an even mid-gray rather than alias.
    func testLargeJPEGReductionResamplesWithoutAliasing() async throws {
        let scaler = try makeScaler()
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.stripedJPEG()))
        for (format, metalFormat) in [(PixelBuffer.PixelFormat.rgba8, MTLPixelFormat.rgba8Unorm), (.gray8, .r8Unorm)] {
            let texture = try await source.makeTexture(fitting: CGSize(width: 100, height: 50),
                                                       pixelFormat: format, using: scaler)
            XCTAssertEqual(texture.width, 100)
            XCTAssertEqual(texture.height, 50)
            XCTAssertEqual(texture.pixelFormat, metalFormat)
            let bytes = try readBack(texture, scaler: scaler)
            let stride = format.bytesPerPixel
            let row = (0..<100).map { Int(bytes[(25 * 100 + $0) * stride]) }
            XCTAssertLessThanOrEqual((row.max() ?? 0) - (row.min() ?? 0), 24, "\(format) aliases: \(row)")
            XCTAssertEqual(Double(row.reduce(0, +)) / Double(row.count), 128, accuracy: 24)
            if format == .rgba8 { XCTAssertEqual(bytes[3], 255) }
        }
    }

    // JPEG XL uses its native reduced decode, then the GPU; a smooth gradient must match the CPU path.
    func testJPEGXLTextureMatchesCPUDecode() async throws {
        let scaler = try makeScaler()
        var pixels: [UInt8] = []
        for y in 0..<32 {
            for x in 0..<32 { pixels += [UInt8(x * 8), UInt8(y * 8), 128, 255] }
        }
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.jxl(width: 32, height: 32, rgba: pixels)))
        let target = CGSize(width: 12, height: 12)
        let texture = try await source.makeTexture(fitting: target, using: scaler)
        XCTAssertEqual(texture.width, 12)
        XCTAssertEqual(texture.height, 12)
        let bytes = try readBack(texture, scaler: scaler)
        let expected = try source.decode(targetSize: target)
        for (x, y) in [(2, 2), (6, 6), (9, 3), (3, 9)] {
            let pixel = expected.pixel(at: x, y: y)
            let offset = (y * 12 + x) * 4
            XCTAssertEqual(Int(bytes[offset]), Int(pixel.r), accuracy: 10)
            XCTAssertEqual(Int(bytes[offset + 1]), Int(pixel.g), accuracy: 10)
            XCTAssertEqual(Int(bytes[offset + 2]), Int(pixel.b), accuracy: 10)
            XCTAssertEqual(bytes[offset + 3], pixel.a)
        }
    }

    // Formats without a reduced decode use the CPU path and upload its exact output.
    func testOtherFormatsUseCPUDecodeAndNeverUpscale() async throws {
        let scaler = try makeScaler()
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.data(width: 40, height: 20, quadrants: true)))
        XCTAssertEqual(source.fileFormat, .png)
        let texture = try await source.makeTexture(fitting: CGSize(width: 400, height: 400), using: scaler)
        XCTAssertEqual(texture.width, 40)
        XCTAssertEqual(texture.height, 20)
        let bytes = try readBack(texture, scaler: scaler)
        let expected = try source.decode()
        let pixel = expected.pixel(at: 30, y: 15)
        let offset = (15 * 40 + 30) * 4
        XCTAssertEqual([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]],
                       [pixel.r, pixel.g, pixel.b, pixel.a])
    }

    func testUnsupportedPixelFormatsThrow() async throws {
        let scaler = try makeScaler()
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.data()))
        for format in [PixelBuffer.PixelFormat.rgb8, .grayAlpha8] {
            do {
                _ = try await source.makeTexture(fitting: CGSize(width: 10, height: 10), pixelFormat: format, using: scaler)
                XCTFail("Expected \(format) to throw")
            } catch ImageDecoderError.invalidOptions {
            }
        }
    }
}
