//
//  SoftwareScalerTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class SoftwareScalerTests: XCTestCase {

    // MARK: - Crop

    func testCropValidRegion() throws {
        let buffer = PixelBuffer(width: 100, height: 100, pixelFormat: .rgba8)
        let cropped = try XCTUnwrap(SoftwareScaler.crop(buffer, to: CGRect(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertEqual(cropped.width, 30)
        XCTAssertEqual(cropped.height, 40)
        XCTAssertEqual(cropped.pixelFormat, .rgba8)
    }

    func testCropPreservesPixelData() throws {
        let buffer = PixelBuffer(width: 4, height: 4, pixelFormat: .rgba8)
        // Write a known pixel at (2, 1)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        let offset = 1 * buffer.bytesPerRow + 2 * 4
        ptr[offset + 0] = 10
        ptr[offset + 1] = 20
        ptr[offset + 2] = 30
        ptr[offset + 3] = 40

        // Crop a region that includes (2, 1) — mapped to (1, 0) in the cropped buffer
        let cropped = try XCTUnwrap(SoftwareScaler.crop(buffer, to: CGRect(x: 1, y: 1, width: 3, height: 2)))
        let p = cropped.pixel(at: 1, y: 0)
        XCTAssertEqual(p.r, 10)
        XCTAssertEqual(p.g, 20)
        XCTAssertEqual(p.b, 30)
        XCTAssertEqual(p.a, 40)
    }

    func testCropFullBuffer() throws {
        let buffer = PixelBuffer(width: 16, height: 8, pixelFormat: .gray8)
        let cropped = try XCTUnwrap(SoftwareScaler.crop(buffer, to: CGRect(x: 0, y: 0, width: 16, height: 8)))
        XCTAssertEqual(cropped.width, 16)
        XCTAssertEqual(cropped.height, 8)
    }

    func testCropOutOfBoundsReturnsNil() {
        let buffer = PixelBuffer(width: 10, height: 10, pixelFormat: .rgba8)
        // Extends past right edge
        XCTAssertNil(SoftwareScaler.crop(buffer, to: CGRect(x: 5, y: 0, width: 10, height: 5)))
        // Extends past bottom edge
        XCTAssertNil(SoftwareScaler.crop(buffer, to: CGRect(x: 0, y: 5, width: 5, height: 10)))
        // Negative origin
        XCTAssertNil(SoftwareScaler.crop(buffer, to: CGRect(x: -1, y: 0, width: 5, height: 5)))
        // Zero size
        XCTAssertNil(SoftwareScaler.crop(buffer, to: CGRect(x: 0, y: 0, width: 0, height: 5)))
    }

    func testCropGrayAlpha() throws {
        let buffer = PixelBuffer(width: 8, height: 8, pixelFormat: .grayAlpha8)
        let ptr = buffer.data.assumingMemoryBound(to: UInt8.self)
        // Write gray=200 alpha=100 at (3, 3)
        let offset = 3 * buffer.bytesPerRow + 3 * 2
        ptr[offset + 0] = 200
        ptr[offset + 1] = 100

        let cropped = try XCTUnwrap(SoftwareScaler.crop(buffer, to: CGRect(x: 2, y: 2, width: 4, height: 4)))
        let p = cropped.pixel(at: 1, y: 1)
        XCTAssertEqual(p.r, 200)
        XCTAssertEqual(p.a, 100)
    }

    // MARK: - Fitting Size

    func testFittingSizeLandscapeIntoBoundingBox() {
        let result = SoftwareScaler.fittingSize(for: CGSize(width: 2000, height: 1000),
                                                in: CGSize(width: 500, height: 500))
        XCTAssertEqual(result.width, 500)
        XCTAssertEqual(result.height, 250)
    }

    func testFittingSizePortraitIntoBoundingBox() {
        let result = SoftwareScaler.fittingSize(for: CGSize(width: 1000, height: 2000),
                                                in: CGSize(width: 500, height: 500))
        XCTAssertEqual(result.width, 250)
        XCTAssertEqual(result.height, 500)
    }

    func testFittingSizeExactFit() {
        let result = SoftwareScaler.fittingSize(for: CGSize(width: 500, height: 500),
                                                in: CGSize(width: 500, height: 500))
        XCTAssertEqual(result.width, 500)
        XCTAssertEqual(result.height, 500)
    }

    func testFittingSizeSmallerThanBounds() {
        // Image smaller than bounding box — scales up
        let result = SoftwareScaler.fittingSize(for: CGSize(width: 100, height: 50),
                                                in: CGSize(width: 400, height: 400))
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(result.height, 200)
    }

    func testFittingSizeNonIntegerResult() {
        // 1920x1080 into 1000x1000 → scale = 1000/1920 ≈ 0.5208
        // width = floor(1920 * 0.5208) = 1000, height = floor(1080 * 0.5208) = 562
        let result = SoftwareScaler.fittingSize(for: CGSize(width: 1920, height: 1080),
                                                in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 562)
    }
}
