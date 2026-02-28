//
//  ImageDestinationTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class ImageDestinationTests: XCTestCase {

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
    }

    private func decodeThumbnailCGImage(for format: ImageSampleData.Format) -> CGImage {
        let source = makeSource(for: format)
        guard let buffer = try? source.decode(targetSize: CGSize(width: 200, height: 200)),
              let cgImage = buffer.makeCGImage() else {
            fatalError("Failed to decode thumbnail for \(format)")
        }
        return cgImage
    }

    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageIOKitTests-\(UUID().uuidString)")
    }

    private func makeTempDir() -> URL {
        let dir = tempDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Encode

    func testEncodeToJPEG() throws {
        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let data = try cgImage.encode(as: .jpeg)
        XCTAssertGreaterThan(data.count, 0)
        // Verify JPEG magic bytes
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testEncodeToPNG() throws {
        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let data = try cgImage.encode(as: .png)
        XCTAssertGreaterThan(data.count, 0)
        // Verify PNG magic bytes
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50)  // 'P'
    }

    func testEncodeToHEIC() throws {
        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let data = try cgImage.encode(as: .heic)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testEncodeQualityAffectsSize() throws {
        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let lowQ = try cgImage.encode(as: .jpeg,
                                      options: EncodeOptions(quality: 0.1))
        let highQ = try cgImage.encode(as: .jpeg,
                                       options: EncodeOptions(quality: 0.95))
        XCTAssertGreaterThan(highQ.count, lowQ.count,
                             "Higher quality should produce larger data")
    }

    // MARK: - Write

    func testWriteToFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let outputURL = dir.appendingPathComponent("output.jpeg")
        try cgImage.write(to: outputURL, as: .jpeg)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        // Verify the file is a valid image
        let source = ImageSource(url: outputURL)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(source?.imageSize.width ?? 0, 0)
    }

    func testWriteToPNG() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cgImage = decodeThumbnailCGImage(for: .jpeg)
        let outputURL = dir.appendingPathComponent("output.png")
        try cgImage.write(to: outputURL, as: .png)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let source = ImageSource(url: outputURL)
        XCTAssertNotNil(source)
    }

    // MARK: - Condition

    func testConditionJPEGPassthrough() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpeg)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        // JPEG that fits within maxDimension should pass through unchanged
        let maxDim = Int(max(source.imageSize.width, source.imageSize.height)) + 1000
        let conditioned = try source.condition(maxDimension: maxDim, to: outputURL)
        // Should return the same source (passthrough)
        XCTAssertTrue(conditioned === source,
                       "JPEG within bounds should pass through without re-encode")
    }

    func testConditionNonJPEGConvertsToJPEG() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .png)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        let conditioned = try source.condition(to: outputURL)

        XCTAssertEqual(conditioned.fileFormat, .jpeg,
                       "Conditioned output should be JPEG")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(conditioned.imageSize.width, 0)
    }

    func testConditionOversizedImageDownscales() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpeg)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        // Use a small maxDimension to force downscaling
        let conditioned = try source.condition(maxDimension: 256, to: outputURL)
        XCTAssertEqual(conditioned.fileFormat, .jpeg)
        let longEdge = max(conditioned.imageSize.width, conditioned.imageSize.height)
        XCTAssertLessThanOrEqual(longEdge, 260,
                                  "Conditioned image should be downscaled to maxDimension")
    }

    func testConditionJXLSource() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpegXL)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        let conditioned = try source.condition(to: outputURL)

        XCTAssertEqual(conditioned.fileFormat, .jpeg,
                       "JXL conditioned output should be JPEG")
        XCTAssertGreaterThan(conditioned.imageSize.width, 0)
    }

    // MARK: - Transcode

    func testTranscodePNGToJPEG() throws {
        let source = makeSource(for: .png)
        let data = try autoreleasepool {
            try source.transcode(to: .jpeg)
        }
        XCTAssertGreaterThan(data.count, 0)
        // Verify JPEG output
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testTranscodeJXLToJPEG() throws {
        let source = makeSource(for: .jpegXL)
        let data = try source.transcode(to: .jpeg)
        XCTAssertGreaterThan(data.count, 0)
        // Should produce valid JPEG either via reconstruction or re-encode
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testTranscodeJPEGToPNG() throws {
        // Use a small decode to keep test fast
        let jpegURL = ImageSampleData.urlForTestImage(with: .jpeg)
        guard let source = ImageSource(url: jpegURL) else {
            XCTFail("Failed to create source")
            return
        }
        let data = try source.transcode(to: .png)
        XCTAssertGreaterThan(data.count, 0)
        // Verify PNG output
        XCTAssertEqual(data[0], 0x89)
    }

    // MARK: - EncodeOptions

    func testEncodeOptionsQualityClamping() {
        let low = EncodeOptions(quality: -0.5)
        XCTAssertEqual(low.quality, 0.0, accuracy: 0.001)

        let high = EncodeOptions(quality: 1.5)
        XCTAssertEqual(high.quality, 1.0, accuracy: 0.001)

        let normal = EncodeOptions(quality: 0.5)
        XCTAssertEqual(normal.quality, 0.5, accuracy: 0.001)
    }
}
