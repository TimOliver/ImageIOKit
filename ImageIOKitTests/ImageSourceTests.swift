//
//  ImageIOKitTests.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 16/4/2023.
//

import XCTest
@testable import ImageIOKitExample

final class ImageIOKitTests: XCTestCase {

    /// Test to ensure proper failure if invalid data is provided
    func testCreatingImageSourceWithBadDataFails() {
        XCTAssertNil(ImageSource(data: Data()))
    }

    /// Test loading each format we support
    func testCreatingImageSourceWithFilePaths() throws {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let imageURL = ImageSampleData.urlForTestImage(with: format)
                let imageSource = ImageSource(url: imageURL)
                XCTAssertNotNil(imageSource)
            }
        }
    }
}
