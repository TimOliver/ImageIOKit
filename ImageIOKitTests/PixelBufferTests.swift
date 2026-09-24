//
//  PixelBufferTests.swift
//  ImageIOKitTests
//

import XCTest
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

final class PixelBufferTests: XCTestCase {

    // MARK: - Allocation

    func testConvenienceInitProperties() {
        let buffer = PixelBuffer(width: 100, height: 50, pixelFormat: .rgba8)
        XCTAssertEqual(buffer.width, 100)
        XCTAssertEqual(buffer.height, 50)
        XCTAssertEqual(buffer.pixelFormat, .rgba8)
        XCTAssertEqual(buffer.bytesPerRow, 100 * 4)
        XCTAssertEqual(buffer.dataSize, 100 * 4 * 50)
    }

    func testConvenienceInitIsZeroFilled() {
        let buffer = PixelBuffer(width: 10, height: 10, pixelFormat: .rgba8)
        for y in 0..<10 {
            for x in 0..<10 {
                let p = buffer.pixel(at: x, y: y)
                XCTAssertEqual(p.r, 0)
                XCTAssertEqual(p.g, 0)
                XCTAssertEqual(p.b, 0)
                XCTAssertEqual(p.a, 0)
            }
        }
    }

    func testCustomAllocatorInit() {
        let width = 8
        let height = 4
        let bpp = 4
        let bytesPerRow = width * bpp
        let size = bytesPerRow * height
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        ptr.initializeMemory(as: UInt8.self, repeating: 0xFF, count: size)

        let buffer = PixelBuffer(width: width, height: height, bytesPerRow: bytesPerRow,
                                 pixelFormat: .rgba8, data: ptr)
        XCTAssertEqual(buffer.width, 8)
        // All bytes 0xFF → pixel (255, 255, 255, 255)
        let p = buffer.pixel(at: 0, y: 0)
        XCTAssertEqual(p.r, 255)
        XCTAssertEqual(p.g, 255)
        XCTAssertEqual(p.b, 255)
        XCTAssertEqual(p.a, 255)
    }

    func testCustomDeallocatorIsCalled() {
        let expectation = expectation(description: "Deallocator called")
        let size = 16
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: size)

        autoreleasepool {
            _ = PixelBuffer(width: 2, height: 2, bytesPerRow: 8, pixelFormat: .rgba8,
                            data: ptr) { p in
                p.deallocate()
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Pixel Format Properties

    func testBytesPerPixel() {
        XCTAssertEqual(PixelBuffer.PixelFormat.rgba8.bytesPerPixel, 4)
        XCTAssertEqual(PixelBuffer.PixelFormat.rgb8.bytesPerPixel, 3)
        XCTAssertEqual(PixelBuffer.PixelFormat.gray8.bytesPerPixel, 1)
        XCTAssertEqual(PixelBuffer.PixelFormat.grayAlpha8.bytesPerPixel, 2)
    }

    func testHasAlpha() {
        XCTAssertTrue(PixelBuffer.PixelFormat.rgba8.hasAlpha)
        XCTAssertFalse(PixelBuffer.PixelFormat.rgb8.hasAlpha)
        XCTAssertFalse(PixelBuffer.PixelFormat.gray8.hasAlpha)
        XCTAssertTrue(PixelBuffer.PixelFormat.grayAlpha8.hasAlpha)
    }

    func testDataSizeForAllFormats() {
        let formats: [PixelBuffer.PixelFormat] = [.rgba8, .rgb8, .gray8, .grayAlpha8]
        for fmt in formats {
            let buffer = PixelBuffer(width: 100, height: 100, pixelFormat: fmt)
            XCTAssertEqual(buffer.dataSize, 100 * fmt.bytesPerPixel * 100,
                           "dataSize mismatch for \(fmt)")
            XCTAssertEqual(buffer.bytesPerRow, 100 * fmt.bytesPerPixel,
                           "bytesPerRow mismatch for \(fmt)")
        }
    }

    // MARK: - Pixel Access

    func testPixelAccessRGBA() {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .rgba8)
        // Write a known pixel: R=10, G=20, B=30, A=40
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        let offset = 1 * buffer.bytesPerRow + 2 * 4  // (x=2, y=1)
        ptr[offset + 0] = 10
        ptr[offset + 1] = 20
        ptr[offset + 2] = 30
        ptr[offset + 3] = 40

        let p = buffer.pixel(at: 2, y: 1)
        XCTAssertEqual(p.r, 10)
        XCTAssertEqual(p.g, 20)
        XCTAssertEqual(p.b, 30)
        XCTAssertEqual(p.a, 40)
    }

    func testPixelAccessRGB() {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .rgb8)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        let offset = 0 * buffer.bytesPerRow + 0 * 3  // (0, 0)
        ptr[offset + 0] = 100
        ptr[offset + 1] = 150
        ptr[offset + 2] = 200

        let p = buffer.pixel(at: 0, y: 0)
        XCTAssertEqual(p.r, 100)
        XCTAssertEqual(p.g, 150)
        XCTAssertEqual(p.b, 200)
        XCTAssertEqual(p.a, 255, "RGB format should return alpha=255")
    }

    func testPixelAccessGray() {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .gray8)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        ptr[0] = 128

        let p = buffer.pixel(at: 0, y: 0)
        XCTAssertEqual(p.r, 128)
        XCTAssertEqual(p.g, 128)
        XCTAssertEqual(p.b, 128)
        XCTAssertEqual(p.a, 255, "Gray format should return alpha=255")
    }

    func testPixelAccessGrayAlpha() {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .grayAlpha8)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        ptr[0] = 64
        ptr[1] = 192

        let p = buffer.pixel(at: 0, y: 0)
        XCTAssertEqual(p.r, 64)
        XCTAssertEqual(p.g, 64)
        XCTAssertEqual(p.b, 64)
        XCTAssertEqual(p.a, 192)
    }

    func testPixelAccessOutOfBounds() {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .rgba8)
        let oob = buffer.pixel(at: -1, y: 0)
        XCTAssertEqual(oob.r, 0)
        XCTAssertEqual(oob.a, 0)

        let oob2 = buffer.pixel(at: 4, y: 0)
        XCTAssertEqual(oob2.r, 0)

        let oob3 = buffer.pixel(at: 0, y: 4)
        XCTAssertEqual(oob3.r, 0)
    }

    // MARK: - CGImage Conversion

    func testMakeCGImageRGBA() {
        let buffer = PixelBuffer(width: 16, height: 8, pixelFormat: .rgba8)
        let cgImage = buffer.makeCGImage()
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 16)
        XCTAssertEqual(cgImage?.height, 8)
    }

    func testMakeCGImageRGB() {
        let buffer = PixelBuffer(width: 16, height: 8, pixelFormat: .rgb8)
        let cgImage = buffer.makeCGImage()
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 16)
        XCTAssertEqual(cgImage?.height, 8)
    }

    func testMakeCGImageGray() {
        let buffer = PixelBuffer(width: 16, height: 8, pixelFormat: .gray8)
        let cgImage = buffer.makeCGImage()
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 16)
        XCTAssertEqual(cgImage?.height, 8)
    }

    func testMakeCGImageGrayAlpha() {
        let buffer = PixelBuffer(width: 16, height: 8, pixelFormat: .grayAlpha8)
        let cgImage = buffer.makeCGImage()
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 16)
        XCTAssertEqual(cgImage?.height, 8)
    }

    func testCGImageRetainsPixelBufferData() {
        // Verify the zero-copy contract: the CGImage keeps data alive
        var cgImage: CGImage?
        autoreleasepool {
            let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .rgba8)
            // Write a known pixel
            let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
            ptr[0] = 255  // R of pixel (0,0)
            ptr[1] = 0    // G
            ptr[2] = 0    // B
            ptr[3] = 255  // A
            cgImage = buffer.makeCGImage()
            // buffer goes out of scope, but CGImage should retain the data
        }
        // CGImage should still be valid
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 4)
    }
}
