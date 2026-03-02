//
//  JXLDecoderTests.swift
//  ImageIOKitTests
//
//  Tests for JXLDecoder — the memory-efficient libjxl callback decoder.
//

import XCTest
import Darwin.Mach
@testable import ImageIOKitExample

final class JXLDecoderTests: XCTestCase {

    // MARK: - Helpers

    private func jxlURL() -> URL {
        ImageSampleData.urlForTestImage(with: .jpegXL)
    }

    private func physicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    // MARK: - Basic Decode

    func testDecodeProducesValidPixelBuffer() throws {
        let decoder = try XCTUnwrap(JXLDecoder(url: jxlURL()))
        let pixelBuffer = try decoder.decode()

        // Verify dimensions match ImageSource metadata
        let source = try XCTUnwrap(ImageSource(url: jxlURL()))
        XCTAssertEqual(pixelBuffer.width, Int(source.imageSize.width))
        XCTAssertEqual(pixelBuffer.height, Int(source.imageSize.height))
        XCTAssertEqual(pixelBuffer.pixelFormat, .rgba8)

        // Verify non-zero pixel data at sample points
        let center = pixelBuffer.pixel(at: pixelBuffer.width / 2, y: pixelBuffer.height / 2)
        let topLeft = pixelBuffer.pixel(at: 0, y: 0)
        // At least some pixels should be non-zero
        let centerSum = Int(center.r) + Int(center.g) + Int(center.b)
        let topLeftSum = Int(topLeft.r) + Int(topLeft.g) + Int(topLeft.b)
        XCTAssertGreaterThan(centerSum + topLeftSum, 0, "Decoded pixels are all black")
    }

    func testDecodedDimensionsMatchImageIO() throws {
        let decoder = try XCTUnwrap(JXLDecoder(url: jxlURL()))
        let source = try XCTUnwrap(ImageSource(url: jxlURL()))

        let size = decoder.imageSize
        XCTAssertEqual(size.width, Int(source.imageSize.width))
        XCTAssertEqual(size.height, Int(source.imageSize.height))
    }

    func testDecodedPixelsAreReasonable() throws {
        let decoder = try XCTUnwrap(JXLDecoder(url: jxlURL()))
        let pixelBuffer = try decoder.decode()

        // Sample pixels at various locations
        let points = [
            (0, 0),
            (pixelBuffer.width / 2, pixelBuffer.height / 2),
            (pixelBuffer.width - 1, 0),
            (0, pixelBuffer.height - 1),
            (pixelBuffer.width - 1, pixelBuffer.height - 1),
        ]

        var allZero = true
        var allMax = true
        for (x, y) in points {
            let p = pixelBuffer.pixel(at: x, y: y)
            if p.r != 0 || p.g != 0 || p.b != 0 { allZero = false }
            if p.r != 255 || p.g != 255 || p.b != 255 { allMax = false }
            // Alpha should be 255 for an opaque photo
            XCTAssertEqual(p.a, 255, "Expected opaque alpha at (\(x), \(y))")
        }

        XCTAssertFalse(allZero, "All sampled pixels are black — decode likely failed")
        XCTAssertFalse(allMax, "All sampled pixels are white — decode likely failed")
    }

    // MARK: - Memory

    func testCallbackDecodeMemoryIsWithinBudget() throws {
        let url = jxlURL()
        let decoder = try XCTUnwrap(JXLDecoder(url: url))
        let size = decoder.imageSize
        let rawBitmap = Int64(size.width) * Int64(size.height) * 4

        let before = physicalFootprint()
        var pixelBuffer: PixelBuffer?
        autoreleasepool {
            pixelBuffer = try! decoder.decode()

            let during = physicalFootprint()
            let peakDelta = during - before

            // Peak memory during decode should not exceed 5x the raw bitmap.
            // 1x for the output PixelBuffer + libjxl's VarDCT working buffers.
            let budget = rawBitmap * 5
            XCTAssertLessThan(peakDelta, budget,
                "Peak memory \(formatBytes(peakDelta)) exceeded budget \(formatBytes(budget))")
        }

        // After decode, verify the retained PixelBuffer is close to 1x raw bitmap
        XCTAssertNotNil(pixelBuffer)
        let retained = Int64(pixelBuffer!.dataSize)
        XCTAssertEqual(retained, rawBitmap,
            "PixelBuffer size \(formatBytes(retained)) should equal raw bitmap \(formatBytes(rawBitmap))")
    }

    func testMemoryBaselineWithXCTMemoryMetric() throws {
        let url = jxlURL()
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                guard let decoder = JXLDecoder(url: url) else { return }
                let _ = try? decoder.decode()
            }
        }
    }

    // MARK: - Init Paths

    func testDecodeFromData() throws {
        let data = try Data(contentsOf: jxlURL())
        let decoder = try XCTUnwrap(JXLDecoder(data: data))
        let pixelBuffer = try decoder.decode()
        XCTAssertGreaterThan(pixelBuffer.width, 0)
        XCTAssertGreaterThan(pixelBuffer.height, 0)
    }

    func testInvalidDataReturnsNilOrThrows() {
        // Empty data returns nil from init
        XCTAssertNil(JXLDecoder(data: Data()))

        // Garbage data should fail at decode
        let garbage = Data(repeating: 0xDE, count: 256)
        let decoder = JXLDecoder(data: garbage)
        // init may succeed (non-empty data) but decode should fail
        if let decoder {
            XCTAssertThrowsError(try decoder.decode())
        }
    }
}
