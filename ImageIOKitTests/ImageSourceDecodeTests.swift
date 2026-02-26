//
//  ImageSourceDecodeTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

/// Comprehensive tests for ImageSource decode paths across all formats.
final class ImageSourceDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
    }

    // MARK: - Data-Based Init

    func testInitWithDataAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let url = ImageSampleData.urlForTestImage(with: format)
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    XCTFail("Failed to read data for \(format)")
                    return
                }
                let source = ImageSource(data: data)
                XCTAssertNotNil(source, "Data-based init failed for \(format)")
                XCTAssertNotEqual(source?.imageSize ?? .zero, .zero,
                                  "Image size is zero for \(format)")
            }
        }
    }

    // MARK: - Deferred Loading

    func testDeferredLoading() {
        let url = ImageSampleData.urlForTestImage(with: .jpeg)
        let source = ImageSource(url: url, loadImmediately: false)
        XCTAssertNotNil(source, "Deferred init should succeed")
        XCTAssertFalse(source!.isLoaded)
        XCTAssertEqual(source!.imageSize, .zero)

        let loaded = source!.loadImageData()
        XCTAssertTrue(loaded)
        XCTAssertTrue(source!.isLoaded)
        XCTAssertNotEqual(source!.imageSize, .zero)
    }

    func testDeferredLoadingIdempotent() {
        let source = makeSource(for: .jpeg)
        // Already loaded — calling again should be a no-op and return true
        XCTAssertTrue(source.isLoaded)
        XCTAssertTrue(source.loadImageData())
    }

    // MARK: - Metadata

    func testImageSizeConsistentAcrossFormats() {
        // All ApplePark images should have the same pixel dimensions
        var sizes: [CGSize] = []
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                XCTAssertGreaterThan(source.imageSize.width, 0, "\(format) width is 0")
                XCTAssertGreaterThan(source.imageSize.height, 0, "\(format) height is 0")
                sizes.append(source.imageSize)
            }
        }
        // All formats should report the same dimensions
        let reference = sizes[0]
        for (i, size) in sizes.enumerated() {
            XCTAssertEqual(size.width, reference.width, accuracy: 1,
                           "\(ImageSampleData.Format.allCases[i]) width differs")
            XCTAssertEqual(size.height, reference.height, accuracy: 1,
                           "\(ImageSampleData.Format.allCases[i]) height differs")
        }
    }

    func testFileFormatDetectionAllFormats() {
        let expectedFormats: [ImageSampleData.Format: ImageFileFormat] = [
            .jpeg: .jpeg, .png: .png, .webp: .webp,
            .heic: .heic, .avif: .avif, .jpegXL: .jpegXL
        ]
        for (sampleFormat, expected) in expectedFormats {
            autoreleasepool {
                let source = makeSource(for: sampleFormat)
                XCTAssertEqual(source.fileFormat, expected,
                               "Format mismatch for \(sampleFormat)")
            }
        }
    }

    func testColorModelIsRGB() {
        // ApplePark is a photo — should be RGB for all formats
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                XCTAssertEqual(source.colorModel, .rgb,
                               "\(format) should be RGB")
            }
        }
    }

    func testHasAlphaForPhoto() {
        // ApplePark is a photo — JPEG has no alpha, PNG may or may not
        let source = makeSource(for: .jpeg)
        XCTAssertFalse(source.hasAlpha, "JPEG photo should not have alpha")
    }

    // MARK: - Capabilities

    func testJPEGHasRegionDecode() {
        let source = makeSource(for: .jpeg)
        XCTAssertTrue(source.capabilities.contains(.regionDecode))
    }

    func testNonJPEGFormatsLackRegionDecode() {
        let nonJPEG: [ImageSampleData.Format] = [.png, .webp, .heic, .avif, .jpegXL]
        for format in nonJPEG {
            autoreleasepool {
                let source = makeSource(for: format)
                XCTAssertFalse(source.capabilities.contains(.regionDecode),
                               "\(format) should not have regionDecode")
            }
        }
    }

    // MARK: - Estimated Decode Memory

    func testEstimatedDecodeMemoryIsPositive() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                XCTAssertGreaterThan(source.estimatedDecodeMemory, 0,
                                     "\(format) estimatedDecodeMemory should be > 0")
            }
        }
    }

    func testJXLEstimateHigherThanJPEG() {
        let jpeg = makeSource(for: .jpeg)
        let jxl = makeSource(for: .jpegXL)
        // JXL multiplier (4.0) is much higher than JPEG (0.5)
        XCTAssertGreaterThan(jxl.estimatedDecodeMemory, jpeg.estimatedDecodeMemory)
    }

    // MARK: - Thumbnail Generation

    func testThumbnailAllFormats() {
        let thumbSize = CGSize(width: 200, height: 200)
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let thumb = source.makeThumbnail(fittingSize: thumbSize)
                XCTAssertNotNil(thumb, "Thumbnail failed for \(format)")
                guard let thumb else { return }
                // Thumbnail should fit within the requested bounding box (in points)
                XCTAssertLessThanOrEqual(thumb.size.width, thumbSize.width + 1,
                                         "\(format) thumbnail too wide")
                XCTAssertLessThanOrEqual(thumb.size.height, thumbSize.height + 1,
                                         "\(format) thumbnail too tall")
            }
        }
    }

    func testThumbnailPreservesAspectRatio() {
        let source = makeSource(for: .jpeg)
        let thumb = source.makeThumbnail(fittingSize: CGSize(width: 300, height: 300))
        XCTAssertNotNil(thumb)
        guard let thumb else { return }

        let sourceAspect = source.imageSize.width / source.imageSize.height
        let thumbAspect = thumb.size.width / thumb.size.height
        XCTAssertEqual(sourceAspect, thumbAspect, accuracy: 0.1,
                       "Thumbnail should preserve aspect ratio")
    }

    // MARK: - Full Decode

    func testFullDecodeCGImageAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let cgImage = source.decodeFullCGImage()
                XCTAssertNotNil(cgImage, "Full CGImage decode failed for \(format)")
                XCTAssertEqual(cgImage?.width ?? 0, Int(source.imageSize.width),
                               "Width mismatch for \(format)")
                XCTAssertEqual(cgImage?.height ?? 0, Int(source.imageSize.height),
                               "Height mismatch for \(format)")
            }
        }
    }

    func testFullDecodeUIImageAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let image = source.decodeFullImage()
                XCTAssertNotNil(image, "Full UIImage decode failed for \(format)")
            }
        }
    }

    func testFullDecodeCGImageIsCached() {
        let source = makeSource(for: .jpeg)
        let first = source.decodeFullCGImage()
        let second = source.decodeFullCGImage()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        // Same object pointer from cache
        XCTAssertTrue(first === second, "Second call should return cached CGImage")
    }

    // MARK: - Region Decode

    func testRegionDecodeJPEG() {
        let source = makeSource(for: .jpeg)
        let region = CGRect(x: 100, y: 100, width: 500, height: 500)
        let image = source.decodeRegion(region)
        XCTAssertNotNil(image, "JPEG region decode should succeed")
    }

    func testRegionDecodeNonJPEGFallsBackToCrop() {
        let source = makeSource(for: .png)
        let region = CGRect(x: 50, y: 50, width: 200, height: 200)
        let image = source.decodeRegion(region)
        XCTAssertNotNil(image, "Non-JPEG region decode (crop fallback) should succeed")
    }

    func testRegionDecodeClampsToBounds() {
        let source = makeSource(for: .png)
        // Region extends past image bounds — should clamp
        let region = CGRect(x: source.imageSize.width - 100,
                            y: source.imageSize.height - 100,
                            width: 500, height: 500)
        let image = source.decodeRegion(region)
        XCTAssertNotNil(image, "Region decode should clamp to bounds")
    }

    func testRegionDecodeWithTargetSize() {
        let source = makeSource(for: .jpeg)
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let target = CGSize(width: 256, height: 256)
        let image = source.decodeRegion(region, targetSize: target)
        XCTAssertNotNil(image, "JPEG region decode with target size should succeed")
    }

    // MARK: - Raw Decode (PixelBuffer)

    func testRawDecodeDefaultOptions() throws {
        let source = makeSource(for: .jpeg)
        let buffer = try source.decode()
        XCTAssertEqual(buffer.width, Int(source.imageSize.width))
        XCTAssertEqual(buffer.height, Int(source.imageSize.height))
        XCTAssertEqual(buffer.pixelFormat, .rgba8)
    }

    func testRawDecodeWithTargetSize() throws {
        let source = makeSource(for: .jpeg)
        let options = DecodeOptions(targetSize: CGSize(width: 256, height: 256))
        let buffer = try source.decode(options: options)
        // Should be smaller than original
        XCTAssertLessThanOrEqual(buffer.width, 256)
        XCTAssertLessThanOrEqual(buffer.height, 256)
        XCTAssertGreaterThan(buffer.width, 0)
    }

    func testRawDecodeWithCropRect() throws {
        let source = makeSource(for: .jpeg)
        let crop = CGRect(x: 100, y: 100, width: 500, height: 300)
        let options = DecodeOptions(cropRect: crop)
        let buffer = try source.decode(options: options)
        XCTAssertEqual(buffer.width, 500)
        XCTAssertEqual(buffer.height, 300)
    }

    func testRawDecodeWithCropAndTargetSize() throws {
        let source = makeSource(for: .jpeg)
        let crop = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let target = CGSize(width: 200, height: 200)
        let options = DecodeOptions(targetSize: target, cropRect: crop)
        let buffer = try source.decode(options: options)
        XCTAssertLessThanOrEqual(buffer.width, 200)
        XCTAssertLessThanOrEqual(buffer.height, 200)
    }

    func testRawDecodeInvalidCropThrows() {
        let source = makeSource(for: .jpeg)
        let hugeRect = CGRect(x: 99999, y: 99999, width: 100, height: 100)
        let options = DecodeOptions(cropRect: hugeRect)
        XCTAssertThrowsError(try source.decode(options: options)) { error in
            guard let decoderError = error as? ImageDecoderError else {
                XCTFail("Expected ImageDecoderError, got \(error)")
                return
            }
            if case .invalidOptions = decoderError {
                // Expected
            } else {
                XCTFail("Expected invalidOptions, got \(decoderError)")
            }
        }
    }

    func testRawDecodeAllPixelFormats() throws {
        let source = makeSource(for: .jpeg)
        let formats: [PixelBuffer.PixelFormat] = [.rgba8, .rgb8, .gray8, .grayAlpha8]

        for format in formats {
            try autoreleasepool {
                let options = DecodeOptions(targetSize: CGSize(width: 100, height: 100),
                                            pixelFormat: format)
                let buffer = try source.decode(options: options)
                XCTAssertEqual(buffer.pixelFormat, format, "Pixel format mismatch for \(format)")
                XCTAssertGreaterThan(buffer.width, 0)
                XCTAssertGreaterThan(buffer.height, 0)
                XCTAssertEqual(buffer.bytesPerRow, buffer.width * format.bytesPerPixel)
            }
        }
    }

    func testRawDecodeOnUnloadedSourceThrows() {
        let url = ImageSampleData.urlForTestImage(with: .jpeg)
        let source = ImageSource(url: url, loadImmediately: false)!
        XCTAssertThrowsError(try source.decode()) { error in
            guard let decoderError = error as? ImageDecoderError else {
                XCTFail("Expected ImageDecoderError")
                return
            }
            if case .invalidData = decoderError {
                // Expected
            } else {
                XCTFail("Expected invalidData, got \(decoderError)")
            }
        }
    }

    // MARK: - JPEG Reconstruction

    func testReconstructJPEGOnlyForJXL() {
        // Non-JXL formats should return nil
        let nonJXL: [ImageSampleData.Format] = [.jpeg, .png, .webp, .heic, .avif]
        for format in nonJXL {
            autoreleasepool {
                let source = makeSource(for: format)
                XCTAssertNil(source.reconstructJPEG(),
                             "\(format) should not support JPEG reconstruction")
            }
        }
    }

    func testReconstructJPEGForJXL() {
        let source = makeSource(for: .jpegXL)
        let jpegData = source.reconstructJPEG()
        // May be nil if the JXL wasn't derived from JPEG — either result is valid
        if let jpegData {
            // Verify it's valid JPEG (starts with FFD8FF)
            XCTAssertGreaterThan(jpegData.count, 3)
            XCTAssertEqual(jpegData[0], 0xFF)
            XCTAssertEqual(jpegData[1], 0xD8)
            XCTAssertEqual(jpegData[2], 0xFF)
        }
    }
}
