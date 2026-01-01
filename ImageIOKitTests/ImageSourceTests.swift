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
                XCTAssertNotEqual(imageSource?.imageSize ?? .zero, .zero)
            }
        }
    }

    // MARK: - Memory Pressure Tests

    func testLoadingJPEGImageMemoryHighMark() {
        let thumbnailSize = CGSize(width: 200, height: 200)
        let imageURL = ImageSampleData.urlForTestImage(with: .jpeg)
        guard let imageSource = ImageSource(url: imageURL) else {
            XCTFail("Unable to load Image")
            return
        }

        measure(metrics: [XCTMemoryMetric()]) {
            let image = imageSource.makeThumbnail(fittingSize: thumbnailSize)
            XCTAssertNotNil(image)
        }
    }
}
