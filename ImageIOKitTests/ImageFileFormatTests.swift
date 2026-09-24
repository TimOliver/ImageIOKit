//
//  ImageFileFormatTests.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 1/1/2026.
//

import XCTest
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

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

    // Test invalid datat to confirm the header validation code fails correctly.
    public func testImageFormatFileHeadersWithInvalidData() {
        guard let textData = "Hello world!".data(using: .utf8) else {
            XCTFail("Unable to generate test data")
            return
        }
        XCTAssertFalse(ImageFileFormat.isValidFileFormat(data: textData))

        guard let shortData = "XD".data(using: .utf8) else {
            XCTFail("Unable to generate test data")
            return
        }
        XCTAssertFalse(ImageFileFormat.isValidFileFormat(data: shortData))
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

extension ImageFileFormatTests {
    private func ftyp(major: String, compatible: [String], extended: Bool = false) -> Data {
        let length = (extended ? 24 : 16) + compatible.count * 4
        var bytes: [UInt8] = [0, 0, 0, UInt8(extended ? 1 : length)] + Array("ftyp".utf8)
        if extended { bytes += [0, 0, 0, 0, 0, 0, 0, UInt8(length)] }
        bytes += Array(major.utf8) + [0, 0, 0, 0]
        for brand in compatible { bytes += Array(brand.utf8) }
        return Data(bytes)
    }

    func testHEIFFamilyDetectionUsesBrands() {
        XCTAssertEqual(ImageFileFormat.detect(from: ftyp(major: "avif", compatible: ["avif", "mif1", "miaf", "MA1A", "MA1B"])), .avif)
        XCTAssertEqual(ImageFileFormat.detect(from: ftyp(major: "mif1", compatible: ["miaf", "avif"])), .avif)
        XCTAssertEqual(ImageFileFormat.detect(from: ftyp(major: "heic", compatible: [])), .heic)
        XCTAssertEqual(ImageFileFormat.detect(from: ftyp(major: "mif1", compatible: ["heic"], extended: true)), .heic)
        XCTAssertEqual(ImageFileFormat.detect(from: ftyp(major: "avis", compatible: [], extended: true)), .avif)
        XCTAssertNil(ImageFileFormat.detect(from: ftyp(major: "mp42", compatible: ["mp41"])))
        XCTAssertNil(ImageFileFormat.detect(from: ftyp(major: "avif", compatible: ["mif1"]).dropLast()))
    }

    func testFormatDetectionWorksWithNonzeroDataIndices() {
        let data = Data([0, 1, 2, 0xff, 0xd8, 0xff]).dropFirst(3)
        XCTAssertEqual(ImageFileFormat.detect(from: data), .jpeg)
    }

    func testImageSourceTrustsContentOverExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticImage.data().write(to: url)
        let source = try XCTUnwrap(ImageSource(url: url))
        XCTAssertEqual(source.fileFormat, .png)
        XCTAssertFalse(source.isRegionDecodable)
    }
}
