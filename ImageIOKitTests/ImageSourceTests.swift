//
//  ImageIOKitTests.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 16/4/2023.
//

import XCTest
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

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
    func testJXLMetadataPreservesCustomICCProfileName() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let original = try XCTUnwrap(space.copyICCData()) as Data
        let profile = SyntheticImage.namedICC(original, name: "Reader Test Profile")
        let data = SyntheticImage.jxl(icc: profile)
        XCTAssertEqual(JXLDecoder(data: data)?.metadata?.colorProfile, "Reader Test Profile")
        let source = try XCTUnwrap(ImageSource(data: data))
        XCTAssertEqual(source.colorProfile, "Reader Test Profile")
    }

    func testJXLMetadataLoadsFromSlicedDataAndMislabeledURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        for orientation in UInt32(1)...8 {
            for container in [false, true] {
                let data = SyntheticImage.jxl(width: 12, height: 8, orientation: orientation,
                                              container: container)
                var prefixed = Data([1, 2, 3])
                prefixed.append(data)
                try data.write(to: url)
                let fromData = try XCTUnwrap(ImageSource(data: prefixed.dropFirst(3)))
                let fromURL = try XCTUnwrap(ImageSource(url: url, loadImmediately: false))
                XCTAssertFalse(fromURL.isLoaded)
                XCTAssertTrue(fromURL.loadImageData())
                XCTAssertTrue(fromURL.loadImageData())
                for source in [fromData, fromURL] {
                    XCTAssertTrue(source.isLoaded)
                    XCTAssertEqual(source.fileFormat, .jpegXL)
                    XCTAssertEqual(source.orientation.rawValue, orientation)
                    XCTAssertEqual(source.imageSize, orientation >= 5
                        ? CGSize(width: 8, height: 12) : CGSize(width: 12, height: 8))
                    XCTAssertTrue(source.hasAlpha)
                    XCTAssertEqual(source.colorModel, .rgb)
                    XCTAssertNotNil(source.colorProfile)
                    let full = try source.decode()
                    XCTAssertEqual(full.width, orientation >= 5 ? 8 : 12)
                    XCTAssertEqual(full.height, orientation >= 5 ? 12 : 8)
                    XCTAssertEqual(full.pixel(at: 0, y: 0).r, 128)
                    XCTAssertEqual(full.pixel(at: 0, y: 0).a, 128)
                }
            }
        }
    }

    func testJXLFullDecodeAndPNGEncodingWithoutImageIOSource() throws {
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.jxl(width: 12, height: 8, orientation: 6)))
        source.cgImageSource = nil
        let full = try XCTUnwrap(source.decodeFullCGImage())
        XCTAssertEqual(full.width, 8)
        XCTAssertEqual(full.height, 12)
        XCTAssertTrue(source.decodeFullCGImage() === full)
        let crop = try source.decode(cropRect: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(crop.width, 3)
        XCTAssertEqual(crop.height, 4)
        XCTAssertEqual(crop.pixel(at: 0, y: 0).a, 128)
        let png = try source.encoded(as: .png)
        let restored = try XCTUnwrap(ImageSource(data: png))
        XCTAssertEqual(restored.imageSize, CGSize(width: 8, height: 12))
        XCTAssertEqual(try restored.decode().pixel(at: 0, y: 0).a, 128)
    }

    func testJXLConditionedJPEGWithoutImageIOSource() throws {
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.jxl(width: 12, height: 8)))
        source.cgImageSource = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        for (bound, expected) in [(4, CGSize(width: 4, height: 2)), (32, CGSize(width: 12, height: 8))] {
            let jpeg = try source.writeConditionedJPEG(maxDimension: bound, to: url, quality: 0.95)
            XCTAssertEqual(jpeg.fileFormat, .jpeg)
            XCTAssertEqual(jpeg.imageSize, expected)
            XCTAssertFalse(jpeg.hasAlpha)
            XCTAssertEqual(try jpeg.decode().pixel(at: 0, y: 0).r, 128, accuracy: 3)
        }
    }

    func testInvalidJXLHeadersLeaveSourceUnloaded() throws {
        let inputs = [Data([0xff, 0x0a]), Data([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 13, 10, 135, 10]),
                      Data("not an image".utf8)]
        for data in inputs {
            let deferred = try XCTUnwrap(ImageSource(data: data, loadImmediately: false))
            XCTAssertFalse(deferred.loadImageData())
            XCTAssertFalse(deferred.isLoaded)
            XCTAssertEqual(deferred.imageSize, .zero)
            XCTAssertNil(deferred.fileFormat)
            XCTAssertNil(ImageSource(data: data))
        }
    }

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
