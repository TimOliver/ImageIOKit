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
}

extension ImageSourceTests {
    private struct Constants {
        static let thumbnailSize = CGSize(width: 200, height: 200)
    }

    // MARK: - Memory Pressure Tests

    private func makeImageSource(for format: ImageSampleData.Format) -> ImageSource {
        let imageURL = ImageSampleData.urlForTestImage(with: format)
        guard let imageSource = ImageSource(url: imageURL) else {
            fatalError("Unable to create image source")
        }
        return imageSource
    }

    func testLoadingJPEGImageMemoryHighMark() {
        let imageSource = makeImageSource(for: .jpeg)
        autoreleasepool {
            measure(metrics: [XCTMemoryMetric()]) {
                let image = imageSource.makeThumbnail(fittingSize: Constants.thumbnailSize)
                XCTAssertNotNil(image)
            }
        }
    }

    func testLoadingPNGImageMemoryHighMark() {
        let imageSource = makeImageSource(for: .png)
        autoreleasepool {
            measure(metrics: [XCTMemoryMetric()]) {
                let image = imageSource.makeThumbnail(fittingSize: Constants.thumbnailSize)
                XCTAssertNotNil(image)
            }
        }
    }

    func testLoadingWebPImageMemoryHighMark() {
        let imageSource = makeImageSource(for: .webp)
        autoreleasepool {
            measure(metrics: [XCTMemoryMetric()]) {
                let image = imageSource.makeThumbnail(fittingSize: Constants.thumbnailSize)
                XCTAssertNotNil(image)
            }
        }
    }

    func testLoadingAVIFImageMemoryHighMark() {
        let imageSource = makeImageSource(for: .avif)
        autoreleasepool {
            measure(metrics: [XCTMemoryMetric()]) {
                let image = imageSource.makeThumbnail(fittingSize: Constants.thumbnailSize)
                XCTAssertNotNil(image)
            }
        }
    }

    func testLoadingJXLImageMemoryHighMark() {
        let imageSource = makeImageSource(for: .jpegXL)
        autoreleasepool {
            measure(metrics: [XCTMemoryMetric()]) {
                let image = imageSource.makeThumbnail(fittingSize: Constants.thumbnailSize)
                XCTAssertNotNil(image)
            }
        }
    }
}
