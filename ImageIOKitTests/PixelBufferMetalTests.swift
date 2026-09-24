//
//  PixelBufferMetalTests.swift
//  ImageIOKitTests
//

import XCTest
import Metal
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

final class PixelBufferMetalTests: XCTestCase {

    // MARK: - Metal Pixel Format Mapping

    func testMetalPixelFormatRGBA8() {
        XCTAssertEqual(PixelBuffer.PixelFormat.rgba8.metalPixelFormat, .rgba8Unorm)
    }

    func testMetalPixelFormatGray8() {
        XCTAssertEqual(PixelBuffer.PixelFormat.gray8.metalPixelFormat, .r8Unorm)
    }

    func testMetalPixelFormatGrayAlpha8() {
        XCTAssertEqual(PixelBuffer.PixelFormat.grayAlpha8.metalPixelFormat, .rg8Unorm)
    }

    func testMetalPixelFormatRGB8ReturnsNil() {
        XCTAssertNil(PixelBuffer.PixelFormat.rgb8.metalPixelFormat)
    }

    // MARK: - makeTexture

    func testMakeTextureRGBA8() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 16, height: 16, pixelFormat: .rgba8)

        let texture = try XCTUnwrap(buffer.makeTexture(device: device))
        XCTAssertEqual(texture.width, 16)
        XCTAssertEqual(texture.height, 16)
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
    }

    func testMakeTextureGray8() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 8, height: 4, pixelFormat: .gray8)

        let texture = try XCTUnwrap(buffer.makeTexture(device: device))
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 4)
        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
    }

    func testMakeTextureGrayAlpha8() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 32, height: 32, pixelFormat: .grayAlpha8)

        let texture = try XCTUnwrap(buffer.makeTexture(device: device))
        XCTAssertEqual(texture.pixelFormat, .rg8Unorm)
    }

    func testMakeTextureRGB8ReturnsNil() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 16, height: 16, pixelFormat: .rgb8)
        XCTAssertNil(buffer.makeTexture(device: device))
    }

    func testMakeTextureCustomUsage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 16, height: 16, pixelFormat: .rgba8)

        let texture = try XCTUnwrap(
            buffer.makeTexture(device: device, usage: [.shaderRead, .shaderWrite])
        )
        XCTAssertTrue(texture.usage.contains(.shaderRead))
        XCTAssertTrue(texture.usage.contains(.shaderWrite))
    }

    func testMakeTexturePixelDataIsCopied() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal not available")
        let buffer = PixelBuffer(width: 2, height: 2, pixelFormat: .rgba8)

        // Write a known pixel: red at (0,0)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        ptr[0] = 255  // R
        ptr[1] = 0    // G
        ptr[2] = 0    // B
        ptr[3] = 255  // A

        let texture = try XCTUnwrap(buffer.makeTexture(device: device))

        // Read back from texture
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(&pixel, bytesPerRow: 2 * 4,
                         from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel[0], 255, "Red channel should be 255")
        XCTAssertEqual(pixel[3], 255, "Alpha channel should be 255")
    }
}
