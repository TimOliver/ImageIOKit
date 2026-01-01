//
//  ImageFileFormatTests.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 1/1/2026.
//

import XCTest
@testable import ImageIOKitExample

/// Unit tests related to the ImageFileFormat enum.
final class ImageFileFormatTests: XCTestCase {

    // Test to make sure the valid file extension test fails when

    public func testImageFormatFileInvalidExtensions() {
        let textURL = URL(fileURLWithPath: "hello.txt")
        XCTAssertFalse(ImageFileFormat.isValidFileName(at: textURL))

        let emptyURL = URL(fileURLWithPath: "")
        XCTAssertFalse(ImageFileFormat.isValidFileName(at: emptyURL))
    }

    // Test to make sure all of the sample image files are recognized
    // as image files via their path extension.
    public func testImageFormatFileExtensions() {
        for format in ImageSampleData.Format.allCases {
            let url = ImageSampleData.urlForTestImage(with: format)
            XCTAssertTrue(ImageFileFormat.isValidFileName(at: url))
        }
    }

    // Test to make sure all sample image files are recognized
    // as valid images by checking their magic numbers in their headers.
    public func testImageFormatFileHeaders() {
        for format in ImageSampleData.Format.allCases {
            let url = ImageSampleData.urlForTestImage(with: format)
            autoreleasepool {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    XCTFail("Unable to locate an image file at \(url)")
                    return
                }
                XCTAssertTrue(ImageFileFormat.isValidFileFormat(data: data))
            }
        }
    }
}
