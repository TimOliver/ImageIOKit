import XCTest
import ImageIO
#if SWIFT_PACKAGE
@testable import ImageIOKit
#else
@testable import ImageIOKitExample
#endif

final class WebPImageDecoderTests: XCTestCase {
    private func fixture(_ name: String = "opaque-lossless") throws -> Data {
        try Data(contentsOf: ImageSampleData.urlForWebPFixture(name))
    }

    private func bytes(_ buffer: PixelBuffer) -> Data {
        Data(bytes: buffer.data, count: buffer.dataSize)
    }

    private func render(_ image: CGImage) throws -> PixelBuffer {
        let result = PixelBuffer(width: image.width, height: image.height, pixelFormat: .rgba8)
        let context = try XCTUnwrap(CGContext(data: result.data, width: result.width, height: result.height,
            bitsPerComponent: 8, bytesPerRow: result.bytesPerRow, space: result.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return result
    }

    func testURLDataAndSlicedDataDecoding() throws {
        let data = try fixture()
        let prefixed = Data([0, 1, 2, 3]) + data
        let url = ImageSampleData.urlForWebPFixture("opaque-lossless")
        let reference = try XCTUnwrap(WebPImageDecoder(url: url)).decode()
        for input in [data, prefixed.dropFirst(4)] {
            let decoder = try XCTUnwrap(WebPImageDecoder(data: input))
            XCTAssertEqual(decoder.imageSize, CGSize(width: 64, height: 32))
            XCTAssertEqual(bytes(try decoder.decode()), bytes(reference))
        }
        XCTAssertEqual(reference.pixel(at: 1, y: 2).r, 84)
        XCTAssertEqual(reference.pixel(at: 1, y: 2).g, 148)
    }

    func testNativeScalingFitsBothBoundsAndNeverUpscales() throws {
        for name in ["opaque-lossless", "opaque-lossy", "alpha-lossless", "alpha-lossy"] {
            let decoder = try XCTUnwrap(WebPImageDecoder(data: fixture(name)))
            for (target, expected) in [(CGSize(width: 40, height: 8), CGSize(width: 16, height: 8)),
                                       (CGSize(width: 8, height: 40), CGSize(width: 8, height: 4)),
                                       (CGSize(width: 400, height: 400), CGSize(width: 64, height: 32)),
                                       (CGSize(width: 1, height: 1), CGSize(width: 1, height: 1))] {
                let result = try decoder.decode(targetSize: target)
                XCTAssertEqual(CGSize(width: result.width, height: result.height), expected, name)
                XCTAssertEqual(result.dataSize, result.width * result.height * 4)
            }
        }
    }

    func testRawAndThumbnailPathsUseNativeDecodeWithoutImageIO() throws {
        let data = try fixture("alpha-lossless")
        let source = try XCTUnwrap(ImageSource(data: data))
        source.cgImageSource = nil // A fallback would fail, proving this exercises the new path.
        let target = CGSize(width: 23, height: 9)
        let expected = try XCTUnwrap(WebPImageDecoder(data: data)).decode(targetSize: target)
        let actual = try source.decode(targetSize: target)
        XCTAssertEqual(bytes(actual), bytes(expected))
        let thumbnail = try XCTUnwrap(source.makeThumbnail(fittingSize: target)?.cgImage)
        XCTAssertEqual(thumbnail.width, expected.width)
        XCTAssertEqual(thumbnail.height, expected.height)
        XCTAssertEqual(thumbnail.alphaInfo, .premultipliedLast)
        XCTAssertNil(source.fullDecodeCache.object(forKey: ImageSource.fullDecodeCacheKey as NSString))
    }

    func testPremultipliedAlphaAndOpaqueBlackCompositing() throws {
        let source = try XCTUnwrap(ImageSource(data: fixture("alpha-lossless")))
        let rgba = try source.decode()
        let rgb = try source.decode(pixelFormat: .rgb8)
        for y in 0..<4 {
            for x in 0..<4 {
                let pixel = rgba.pixel(at: x, y: y)
                let alpha = ((x + y) % 4) * 64
                XCTAssertEqual(Int(pixel.a), alpha)
                XCTAssertEqual(Int(pixel.r), (20 + (x % 4) * 64) * alpha / 255, accuracy: 1)
                XCTAssertEqual(Int(pixel.g), (20 + (y % 4) * 64) * alpha / 255, accuracy: 1)
                XCTAssertEqual(Int(pixel.b), 80 * alpha / 255, accuracy: 1)
                XCTAssertEqual(rgb.pixel(at: x, y: y).r, pixel.r)
            }
        }
        for name in ["alpha-lossless", "alpha-lossy"] {
            let decoder = try XCTUnwrap(WebPImageDecoder(data: fixture(name)))
            let scaled = try decoder.decode(targetSize: CGSize(width: 17, height: 7))
            for y in 0..<scaled.height {
                for x in 0..<scaled.width {
                    let pixel = scaled.pixel(at: x, y: y)
                    XCTAssertLessThanOrEqual(pixel.r, pixel.a)
                    XCTAssertLessThanOrEqual(pixel.g, pixel.a)
                    XCTAssertLessThanOrEqual(pixel.b, pixel.a)
                }
            }
        }
    }

    func testAllOutputPixelFormats() throws {
        let source = try XCTUnwrap(ImageSource(data: fixture("alpha-lossless")))
        source.cgImageSource = nil
        for format: PixelBuffer.PixelFormat in [.rgba8, .rgb8, .gray8, .grayAlpha8] {
            let result = try source.decode(targetSize: CGSize(width: 16, height: 8), pixelFormat: format)
            XCTAssertEqual(result.pixelFormat, format)
            XCTAssertEqual(result.dataSize, 16 * 8 * format.bytesPerPixel)
            XCTAssertNotNil(result.makeCGImage())
        }
    }

    func testNativeCropsAndFractionalClamping() throws {
        for name in ["opaque-lossless", "opaque-lossy"] {
            let source = try XCTUnwrap(ImageSource(data: fixture(name)))
            source.cgImageSource = nil
            let scaled = try source.decode(targetSize: CGSize(width: 8, height: 8),
                                            cropRect: CGRect(x: 2, y: 4, width: 20, height: 10))
            XCTAssertEqual(scaled.width, 8)
            XCTAssertEqual(scaled.height, 4)
            let clamped = try source.decode(cropRect: CGRect(x: -1.5, y: -0.5, width: 12, height: 8))
            XCTAssertEqual(clamped.width, 11)
            XCTAssertEqual(clamped.height, 8)
        }
        let data = try fixture()
        let decoder = try XCTUnwrap(WebPImageDecoder(data: data))
        let full = try decoder.decode()
        let crop = CGRect(x: 1, y: 3, width: 13, height: 7)
        let exact = try decoder.decode(cropRect: crop)
        XCTAssertEqual(bytes(exact), bytes(try XCTUnwrap(SoftwareScaler.crop(full, to: crop))))
    }

    func testOddLossyCropFallsBackWithoutMovingTheOrigin() throws {
        let data = try fixture("opaque-lossy")
        let crop = CGRect(x: 1, y: 3, width: 13, height: 7)
        let decoder = try XCTUnwrap(WebPImageDecoder(data: data))
        XCTAssertThrowsError(try decoder.decode(cropRect: crop)) { error in
            guard case ImageDecoderError.unsupportedOperation = error else { return XCTFail("\(error)") }
        }
        let source = try XCTUnwrap(ImageSource(data: data))
        let result = try source.decode(cropRect: crop)
        let full = try XCTUnwrap(source.fullDecodeCache.object(forKey: ImageSource.fullDecodeCacheKey as NSString))
        let reference = try render(XCTUnwrap(full.cropping(to: crop)))
        XCTAssertEqual(bytes(result), bytes(reference))
    }

    func testICCProfileIsRetainedAndConvertedToSRGB() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let icc = try XCTUnwrap(space.copyICCData()) as Data
        let data = try metadata(icc: icc)
        let decoder = try XCTUnwrap(WebPImageDecoder(data: data))
        let native = try decoder.decode()
        XCTAssertEqual(native.colorSpace.name, CGColorSpace.displayP3)
        let source = try XCTUnwrap(ImageSource(data: data))
        let result = try source.decode()
        let expected = try render(XCTUnwrap(native.makeCGImage()))
        XCTAssertEqual(result.colorSpace.name, CGColorSpace.sRGB)
        XCTAssertEqual(bytes(result), bytes(expected))
        XCTAssertNotEqual(bytes(result), bytes(native))
        let thumbnail = try XCTUnwrap(source.makeThumbnail(fittingSize: source.imageSize)?.cgImage)
        XCTAssertEqual(thumbnail.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(bytes(try render(thumbnail)), bytes(expected))
    }

    func testUnsupportedICCProfileRequestsFallback() throws {
        let data = try metadata(icc: Data([1, 2, 3, 4]))
        let decoder = try XCTUnwrap(WebPImageDecoder(data: data))
        XCTAssertThrowsError(try decoder.decode()) { error in
            guard case ImageDecoderError.unsupportedOperation = error else { return XCTFail("\(error)") }
        }
    }

    func testOrientationFallsBackToUprightImageIOPixels() throws {
        for orientation in UInt8(2)...8 {
            let source = try XCTUnwrap(ImageSource(data: metadata(orientation: orientation)))
            let expectedSize = orientation >= 5 ? CGSize(width: 32, height: 64) : CGSize(width: 64, height: 32)
            XCTAssertEqual(source.imageSize, expectedSize)
            let raw = try source.decode()
            let expected = try render(XCTUnwrap(source.decodeFullCGImage()))
            XCTAssertEqual(bytes(raw), bytes(expected))
            let crop = CGRect(x: 1, y: 3, width: 8, height: 10)
            XCTAssertEqual(bytes(try source.decode(cropRect: crop)),
                           bytes(try XCTUnwrap(SoftwareScaler.crop(expected, to: crop))))
            let thumbnail = try XCTUnwrap(source.makeThumbnail(fittingSize: CGSize(width: 16, height: 16)))
            XCTAssertEqual(thumbnail.size, orientation >= 5 ? CGSize(width: 8, height: 16) : CGSize(width: 16, height: 8))
            XCTAssertEqual(thumbnail.imageOrientation, .up)
        }
    }

    func testAnimationFallsBackToImageIO() throws {
        let data = try fixture("animated")
        XCTAssertNil(WebPImageDecoder(data: data))
        let source = try XCTUnwrap(ImageSource(data: data))
        XCTAssertNotNil(source.makeThumbnail(fittingSize: CGSize(width: 16, height: 8)))
        let result = try source.decode()
        let expected = try render(XCTUnwrap(source.decodeFullCGImage()))
        XCTAssertEqual(bytes(result), bytes(expected))
    }

    func testInvalidInputsAndOptionsFailSafely() throws {
        XCTAssertNil(WebPImageDecoder(data: Data()))
        XCTAssertNil(WebPImageDecoder(data: Data([1, 2, 3])))
        let data = try fixture()
        for count in [12, 20, data.count - 8] {
            if let decoder = WebPImageDecoder(data: data.prefix(count)) {
                XCTAssertThrowsError(try decoder.decode())
            }
        }
        let decoder = try XCTUnwrap(WebPImageDecoder(data: data))
        for target in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 4), CGSize(width: 4, height: CGFloat.nan)] {
            XCTAssertThrowsError(try decoder.decode(targetSize: target))
        }
        XCTAssertThrowsError(try decoder.decode(cropRect: CGRect(x: 100, y: 100, width: 10, height: 10)))
    }

    func testCGImageKeepsDecodedPixelsAlive() throws {
        let image: CGImage = try autoreleasepool {
            let decoder = try XCTUnwrap(WebPImageDecoder(data: fixture()))
            return try XCTUnwrap(decoder.decode().makeCGImage())
        }
        let result = try render(image)
        XCTAssertEqual(result.pixel(at: 1, y: 2).r, 84)
        XCTAssertEqual(result.pixel(at: 1, y: 2).g, 148)
    }

    func testNativeThumbnailPerformance() {
        let url = ImageSampleData.urlForTestImage(with: .webp)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            autoreleasepool {
                let source = ImageSource(url: url)
                let result = try? source?.decode(targetSize: CGSize(width: 256, height: 256))
                XCTAssertNotNil(result)
            }
        }
    }

    func testImageIOThumbnailPerformance() {
        let url = ImageSampleData.urlForTestImage(with: .webp)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            autoreleasepool {
                let source = ImageSource(url: url)
                guard let imageSource = source?.cgImageSource else { return XCTFail("Missing source") }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256]
                guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                    return XCTFail("Missing thumbnail")
                }
                let result = try? render(image)
                XCTAssertNotNil(result)
            }
        }
    }

    private func metadata(icc: Data? = nil, orientation: UInt8? = nil) throws -> Data {
        func littleEndian(_ value: Int, count: Int) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func chunk(_ name: String, _ value: Data) -> Data {
            Data(name.utf8) + littleEndian(value.count, count: 4) + value
                + (value.count % 2 == 1 ? Data([0]) : Data())
        }
        let flags: UInt8 = (icc != nil ? 0x20 : 0) | (orientation != nil ? 0x08 : 0)
        let header = Data([flags, 0, 0, 0]) + littleEndian(63, count: 3) + littleEndian(31, count: 3)
        var chunks = chunk("VP8X", header)
        if let icc { chunks += chunk("ICCP", icc) }
        chunks += try fixture().dropFirst(12)
        if let orientation {
            // Little-endian TIFF, one SHORT orientation entry and no next IFD.
            let exif = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0,
                             0x12, 1, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0])
            chunks += chunk("EXIF", exif)
        }
        return Data("RIFF".utf8) + littleEndian(chunks.count + 4, count: 4) + Data("WEBP".utf8) + chunks
    }
}
