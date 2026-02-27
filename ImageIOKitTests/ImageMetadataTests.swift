//
//  ImageMetadataTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class ImageMetadataTests: XCTestCase {

    // MARK: - Init & Properties

    func testInitStoresAllProperties() {
        let meta = ImageMetadata(width: 1920, height: 1080, hasAlpha: true,
                                 colorModel: .rgb, colorProfile: "Display P3")
        XCTAssertEqual(meta.width, 1920)
        XCTAssertEqual(meta.height, 1080)
        XCTAssertTrue(meta.hasAlpha)
        XCTAssertEqual(meta.colorModel, .rgb)
        XCTAssertEqual(meta.colorProfile, "Display P3")
    }

    func testInitDefaultsAreNil() {
        let meta = ImageMetadata(width: 640, height: 480, hasAlpha: false)
        XCTAssertNil(meta.colorModel)
        XCTAssertNil(meta.colorProfile)
    }

    func testInitGrayscale() {
        let meta = ImageMetadata(width: 256, height: 256, hasAlpha: false,
                                 colorModel: .grayscale)
        XCTAssertEqual(meta.colorModel, .grayscale)
        XCTAssertFalse(meta.hasAlpha)
    }

    // MARK: - Size

    func testSizeComputedProperty() {
        let meta = ImageMetadata(width: 3024, height: 4032, hasAlpha: false)
        let size = meta.size
        XCTAssertEqual(size.width, 3024)
        XCTAssertEqual(size.height, 4032)
    }

    func testSizeWithSmallDimensions() {
        let meta = ImageMetadata(width: 1, height: 1, hasAlpha: true)
        XCTAssertEqual(meta.size, CGSize(width: 1, height: 1))
    }
}
