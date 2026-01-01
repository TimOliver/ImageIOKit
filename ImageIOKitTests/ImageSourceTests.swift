//
//  ImageIOKitTests.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 16/4/2023.
//

import XCTest
@testable import ImageIOKitExample

/// Tests related to the ImageSource class
final class ImageSourceTests: XCTestCase {

    /// Test to ensure proper failure if invalid data is provided
    func testCreatingImageSourceWithBadDataFails() {
        XCTAssertNil(ImageSource(data: Data()))
        XCTAssertNil(ImageSource(url: URL(fileURLWithPath: "")))
    }

    /// Test loading each format we support
    func testCreatingImageSourceWithFilePaths() throws {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let imageURL = ImageSampleData.urlForTestImage(with: format)
                let imageSource = ImageSource(url: imageURL)
                XCTAssertNotNil(imageSource)

                guard let size = imageSource?.imageSize else {
                    XCTFail("Failed to load size from image")
                    return
                }
                XCTAssertNotEqual(size, .zero)
            }
        }
    }
}
