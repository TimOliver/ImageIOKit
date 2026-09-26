//
//  ImageDestinationTests.swift
//  ImageIOKitTests
//

import XCTest
import ImageIO
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

final class ImageDestinationTests: XCTestCase {

    func testPixelBufferPNGPreservesPaddedPixelsAndAlpha() throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 99, count: 32)
        let buffer = PixelBuffer(width: 3, height: 2, bytesPerRow: 16, pixelFormat: .rgba8, data: memory)
        let rows: [[UInt8]] = [[255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0],
                              [0, 0, 255, 255, 64, 64, 64, 128, 255, 255, 255, 255]]
        for y in 0..<2 {
            rows[y].withUnsafeBytes { memory.advanced(by: y * 16).copyMemory(from: $0.baseAddress!, byteCount: 12) }
        }
        let original = Data(bytes: buffer.data, count: buffer.dataSize)
        let url = directory.appendingPathComponent("page.png")
        try buffer.write(to: url, as: .png)
        let source = try XCTUnwrap(ImageSource(url: url))
        XCTAssertEqual(source.imageSize, CGSize(width: 3, height: 2))
        let reloaded = try source.decode()
        for y in 0..<2 {
            for x in 0..<3 {
                let expected = buffer.pixel(at: x, y: y), actual = reloaded.pixel(at: x, y: y)
                XCTAssertEqual(actual.r, expected.r)
                XCTAssertEqual(actual.g, expected.g)
                XCTAssertEqual(actual.b, expected.b)
                XCTAssertEqual(actual.a, expected.a)
            }
        }
        XCTAssertEqual(Data(bytes: buffer.data, count: buffer.dataSize), original)
    }

    func testPixelBufferJPEGFlattensAlphaOverBlack() throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = PixelBuffer(width: 32, height: 32, pixelFormat: .rgba8)
        let pixels = buffer.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(32 * 32) {
            pixels[i * 4] = 128; pixels[i * 4 + 3] = 128
        }
        let url = directory.appendingPathComponent("page.jpg")
        try buffer.write(to: url, as: .jpeg)
        let source = try XCTUnwrap(ImageSource(url: url))
        XCTAssertEqual(source.fileFormat, .jpeg)
        XCTAssertFalse(source.hasAlpha)
        let pixel = try source.decode().pixel(at: 16, y: 16)
        XCTAssertEqual(Int(pixel.r), 128, accuracy: 2)
        XCTAssertEqual(Int(pixel.g), 0, accuracy: 2)
        XCTAssertEqual(Int(pixel.b), 0, accuracy: 2)
        XCTAssertEqual(pixel.a, 255)
        XCTAssertEqual(buffer.pixel(at: 16, y: 16).a, 128)
    }

    func testPixelBufferJPEGFlattensGrayscaleAlphaOverBlack() throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = PixelBuffer(width: 16, height: 16, pixelFormat: .grayAlpha8)
        let pixels = buffer.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(16 * 16) { pixels[i * 2] = 64; pixels[i * 2 + 1] = 128 }
        let url = directory.appendingPathComponent("gray.jpg")
        try buffer.write(to: url, as: .jpeg, quality: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        let gray = PixelBuffer(width: 16, height: 16, pixelFormat: .gray8)
        let context = try XCTUnwrap(CGContext(data: gray.data, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: gray.bytesPerRow, space: buffer.colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(Int(gray.pixel(at: 8, y: 8).r), 64, accuracy: 2)
    }

    func testPixelBufferWriterRetainsProfileAndSupportsEveryLayout() throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        for format: PixelBuffer.PixelFormat in [.rgba8, .rgb8, .gray8, .grayAlpha8] {
            let rgb = format == .rgb8 || format == .rgba8
            let buffer = PixelBuffer(width: 8, height: 4, pixelFormat: format, colorSpace: rgb ? p3 : nil)
            memset(buffer.data, 255, buffer.dataSize)
            let url = directory.appendingPathComponent("\(format).png")
            try buffer.write(to: url, as: .png)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 8)
            XCTAssertEqual(image.height, 4)
            if rgb { XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3) }
            let pixel = try XCTUnwrap(ImageSource(url: url)).decode().pixel(at: 0, y: 0)
            XCTAssertEqual(pixel.r, 255)
            XCTAssertEqual(pixel.a, 255)
        }
    }

    func testPixelBufferWriteReplacesFileAndCleansUpOnFailure() throws {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page")
        let sentinel = Data("old cache".utf8)
        try sentinel.write(to: url)
        let buffer = PixelBuffer(width: 4, height: 3, pixelFormat: .rgba8)
        XCTAssertThrowsError(try buffer.write(to: url, as: .jpeg, quality: .nan))
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        try buffer.write(to: url, as: .png)
        XCTAssertEqual(ImageSource(url: url)?.fileFormat, .png)
        XCTAssertThrowsError(try buffer.write(to: directory, as: .png))
        XCTAssertThrowsError(try buffer.write(to: directory.appendingPathComponent("missing/page.png"), as: .png))
        XCTAssertThrowsError(try buffer.write(to: URL(string: "https://example.com/page.png")!, as: .png))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["page"])
    }

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
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
        let source = makeSource(for: .jpeg)
        let data = try source.encoded(as: .jpeg)
        XCTAssertGreaterThan(data.count, 0)
        // Verify JPEG magic bytes
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testEncodeToPNG() throws {
        let source = makeSource(for: .jpeg)
        let data = try source.encoded(as: .png)
        XCTAssertGreaterThan(data.count, 0)
        // Verify PNG magic bytes
        XCTAssertEqual(data[0], 0x89)
        XCTAssertEqual(data[1], 0x50)  // 'P'
    }

    func testEncodeToHEIC() throws {
        let source = makeSource(for: .jpeg)
        let data = try source.encoded(as: .heic)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testEncodeQualityAffectsSize() throws {
        // Use a PNG source encoding to JPEG to ensure re-encoding occurs
        // (same-format stream copy would produce identical output regardless of quality)
        let source = makeSource(for: .png)
        let lowQ = try source.encoded(as: .jpeg, quality: 0.1)
        let highQ = try source.encoded(as: .jpeg, quality: 0.95)
        XCTAssertGreaterThan(highQ.count, lowQ.count,
                             "Higher quality should produce larger data")
    }

    // MARK: - Write

    func testWriteToFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpeg)
        let outputURL = dir.appendingPathComponent("output.jpeg")
        try source.write(to: outputURL, as: .jpeg)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        // Verify the file is a valid image
        let written = ImageSource(url: outputURL)
        XCTAssertNotNil(written)
        XCTAssertGreaterThan(written?.imageSize.width ?? 0, 0)
    }

    func testWriteToPNG() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpeg)
        let outputURL = dir.appendingPathComponent("output.png")
        try source.write(to: outputURL, as: .png)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let written = ImageSource(url: outputURL)
        XCTAssertNotNil(written)
    }

    // MARK: - Condition

    func testConditionJPEGPassthrough() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .jpeg)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        // JPEG that fits within maxDimension should pass through unchanged
        let maxDim = Int(max(source.imageSize.width, source.imageSize.height)) + 1000
        let conditioned = try source.writeConditionedJPEG(maxDimension: maxDim, to: outputURL)
        XCTAssertEqual(conditioned.url, outputURL)
        XCTAssertEqual(try Data(contentsOf: outputURL), try Data(contentsOf: XCTUnwrap(source.url)),
                       "JPEG within bounds should be copied without re-encoding")
    }

    func testConditionNonJPEGConvertsToJPEG() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = makeSource(for: .png)
        let outputURL = dir.appendingPathComponent("conditioned.jpeg")
        let conditioned = try source.writeConditionedJPEG(to: outputURL)

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
        let conditioned = try source.writeConditionedJPEG(maxDimension: 256, to: outputURL)
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
        let conditioned = try source.writeConditionedJPEG(to: outputURL)

        XCTAssertEqual(conditioned.fileFormat, .jpeg,
                       "JXL conditioned output should be JPEG")
        XCTAssertGreaterThan(conditioned.imageSize.width, 0)
    }

    // MARK: - Transcode

    func testTranscodePNGToJPEG() throws {
        let source = makeSource(for: .png)
        let data = try autoreleasepool {
            try source.transcoded(to: .jpeg)
        }
        XCTAssertGreaterThan(data.count, 0)
        // Verify JPEG output
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testTranscodeJXLToJPEG() throws {
        let source = makeSource(for: .jpegXL)
        let data = try source.transcoded(to: .jpeg)
        XCTAssertGreaterThan(data.count, 0)
        // Should produce valid JPEG either via reconstruction or re-encode
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testTranscodeJPEGToPNG() throws {
        let source = makeSource(for: .jpeg)
        let data = try source.transcoded(to: .png)
        XCTAssertGreaterThan(data.count, 0)
        // Verify PNG output
        XCTAssertEqual(data[0], 0x89)
    }

    // MARK: - Quality Clamping

    func testEncodeQualityClamping() throws {
        let source = makeSource(for: .png)
        // Out-of-range values should not crash — they are clamped internally
        let underflow = try source.encoded(as: .jpeg, quality: -0.5)
        XCTAssertGreaterThan(underflow.count, 0)
        let overflow = try source.encoded(as: .jpeg, quality: 1.5)
        XCTAssertGreaterThan(overflow.count, 0)
    }
}

extension ImageDestinationTests {
    func testConditionJPEGDataWritesExactBytesAndOverwritesDestination() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = SyntheticImage.data(jpeg: true)
        let source = try XCTUnwrap(ImageSource(data: bytes))
        let url = dir.appendingPathComponent("copied.jpg")
        try Data([0, 1, 2]).write(to: url)
        let written = try source.writeConditionedJPEG(to: url, quality: 0.1)
        XCTAssertEqual(written.url, url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(written.imageSize, source.imageSize)
    }

    func testConditionJPEGSupportsIdenticalSourceAndDestination() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = SyntheticImage.data(jpeg: true)
        let url = dir.appendingPathComponent("same.jpg")
        try bytes.write(to: url)
        let source = try XCTUnwrap(ImageSource(url: url))
        let written = try source.writeConditionedJPEG(to: url)
        XCTAssertEqual(written.url, url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testConditionJPEGPropagatesWriteFailure() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try XCTUnwrap(ImageSource(data: SyntheticImage.data(jpeg: true)))
        XCTAssertThrowsError(try source.writeConditionedJPEG(to: dir.appendingPathComponent("missing/output.jpg")))
        XCTAssertThrowsError(try source.writeConditionedJPEG(maxDimension: 0, to: dir.appendingPathComponent("invalid.jpg")))
    }
}
