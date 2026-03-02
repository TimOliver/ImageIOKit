//
//  MemoryTrackingTests.swift
//  ImageIOKitTests
//
//  Memory budget assertions for decode paths.
//  Uses mach task_info to measure physical memory footprint
//  and validates that known-heavy paths (JXL, large images)
//  stay within their estimated budgets.
//

import XCTest
import Darwin.Mach
@testable import ImageIOKitExample

final class MemoryTrackingTests: XCTestCase {

    // MARK: - Memory Measurement

    /// Returns the current physical memory footprint of the process in bytes.
    /// Uses `phys_footprint` from TASK_VM_INFO which matches what iOS uses
    /// to determine memory pressure and jetsam limits.
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

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
    }

    /// The raw bitmap size for a full RGBA decode of the image.
    private func rawBitmapSize(for source: ImageSource) -> Int64 {
        Int64(source.imageSize.width) * Int64(source.imageSize.height) * 4
    }

    // MARK: - Retained Bitmap Budget

    /// Verifies that a full decode's retained memory is within a reasonable
    /// multiple of the raw bitmap size. This catches leaks of intermediate
    /// buffers that should have been freed after decode completes.
    func testRetainedBitmapBudgetAllFormats() {
        for format in ImageSampleData.Format.allCases {
            let source = makeSource(for: format)
            let bitmap = rawBitmapSize(for: source)

            let before = physicalFootprint()

            autoreleasepool {
                let cgImage = source.decodeFullCGImage()
                XCTAssertNotNil(cgImage, "Decode failed for \(format)")
            }

            // After autoreleasepool, the CGImage is released.
            // The source's internal cache may still hold it, so we
            // measure the delta which includes the cached bitmap.
            let after = physicalFootprint()
            let delta = after - before

            // The retained memory should not exceed 3x the raw bitmap.
            // 1x for the bitmap itself + generous overhead for CGImage metadata,
            // color space data, and system allocations.
            let budget = bitmap * 3
            XCTAssertLessThan(delta, budget,
                "\(format): retained \(formatBytes(delta)), budget \(formatBytes(budget))")
        }
    }

    // MARK: - JXL Decode Budget

    /// Specifically validates that JXL decode via Apple ImageIO doesn't blow
    /// out memory. JXL's VarDCT requires float32 working buffers during decode,
    /// but these should be freed once the output bitmap is produced.
    func testJXLDecodeDoesNotExceedEstimatedBudget() {
        let source = makeSource(for: .jpegXL)
        let budget = Int64(source.estimatedDecodeMemory)

        // Decode and immediately release to measure transient + retained
        let before = physicalFootprint()
        autoreleasepool {
            let image = source.decodeFullCGImage()
            XCTAssertNotNil(image, "JXL decode failed")

            let during = physicalFootprint()
            let peakDelta = during - before

            // Peak during decode (with result held) should not exceed
            // the estimated budget by more than 2x. The estimate already
            // accounts for VarDCT overhead (4x raw bitmap).
            XCTAssertLessThan(peakDelta, budget * 2,
                "JXL peak memory \(formatBytes(peakDelta)) exceeded 2x budget \(formatBytes(budget * 2))")
        }

        // After release, most memory should be reclaimed
        let afterRelease = physicalFootprint()
        let retained = afterRelease - before
        let oneMB: Int64 = 1_048_576
        // Allow some retained memory for system caches, but it shouldn't be huge
        XCTAssertLessThan(retained, oneMB * 50,
            "JXL decode retained \(formatBytes(retained)) after release")
    }

    // MARK: - JPEG Decode is Memory-Efficient

    /// JPEG decode should be the most memory-efficient format due to its
    /// simple decompression and the 0.5x multiplier on estimatedDecodeMemory.
    func testJPEGDecodeIsMemoryEfficient() {
        let source = makeSource(for: .jpeg)
        let bitmap = rawBitmapSize(for: source)

        let before = physicalFootprint()
        autoreleasepool {
            let image = source.decodeFullCGImage()
            XCTAssertNotNil(image)

            let during = physicalFootprint()
            let delta = during - before

            // JPEG decode should use roughly 1x the raw bitmap (the output)
            // plus modest overhead. Definitely under 2x.
            XCTAssertLessThan(delta, bitmap * 2,
                "JPEG decode used \(formatBytes(delta)), expected < \(formatBytes(bitmap * 2))")
        }
    }

    // MARK: - Thumbnail Memory is Low

    /// Thumbnail decode should use drastically less memory than a full decode.
    /// This validates that shrink-on-load actually avoids decoding the full image.
    func testThumbnailMemoryIsLow() {
        for format in ImageSampleData.Format.allCases {
            let source = makeSource(for: format)
            let fullBitmap = rawBitmapSize(for: source)

            var thumbDelta: Int64 = 0
            autoreleasepool {
                let before = physicalFootprint()
                let thumb = source.makeThumbnail(fittingSize: CGSize(width: 200, height: 200))
                XCTAssertNotNil(thumb, "Thumbnail failed for \(format)")
                thumbDelta = physicalFootprint() - before
            }

            // A 200x200 thumbnail is ~160KB in RGBA.
            // The total memory (including any transient decode buffers) should
            // be well under 1/4 of the full bitmap for all formats.
            XCTAssertLessThan(thumbDelta, fullBitmap / 4,
                "\(format): thumbnail used \(formatBytes(thumbDelta)), " +
                "full bitmap \(formatBytes(fullBitmap))")
        }
    }

    // MARK: - Decode + Release Cleanup

    /// Verifies that after decoding and releasing, memory is properly reclaimed.
    /// This catches retain cycles and buffer leaks in the decode pipeline.
    func testDecodeAndReleaseReclaimsMemory() {
        for format in ImageSampleData.Format.allCases {
            let before = physicalFootprint()

            autoreleasepool {
                let source = makeSource(for: format)
                let _ = source.decodeFullCGImage()
                // source and image both go out of scope here
            }

            let after = physicalFootprint()
            let leaked = after - before
            let oneMB: Int64 = 1_048_576

            // After full release, leaked memory should be minimal.
            // Allow 20MB for system caches and allocation granularity.
            XCTAssertLessThan(leaked, oneMB * 20,
                "\(format): leaked \(formatBytes(leaked)) after decode + release")
        }
    }

    // MARK: - Estimated Decode Memory Sanity

    /// Validates that estimatedDecodeMemory is reasonable relative to
    /// the raw bitmap size and the format multipliers.
    func testEstimatedDecodeMemoryMultipliers() {
        let jpeg = makeSource(for: .jpeg)
        let png = makeSource(for: .png)
        let jxl = makeSource(for: .jpegXL)

        let bitmap = rawBitmapSize(for: jpeg)

        // JPEG: 0.5x → less than 1x raw bitmap
        XCTAssertLessThan(Int64(jpeg.estimatedDecodeMemory), bitmap)

        // PNG: 1.5x → between 1x and 2x
        XCTAssertGreaterThan(Int64(png.estimatedDecodeMemory), bitmap)
        XCTAssertLessThan(Int64(png.estimatedDecodeMemory), bitmap * 2)

        // JXL: 4.0x → between 3x and 5x
        XCTAssertGreaterThan(Int64(jxl.estimatedDecodeMemory), bitmap * 3)
        XCTAssertLessThan(Int64(jxl.estimatedDecodeMemory), bitmap * 5)
    }

    // MARK: - Performance Memory Metrics (XCTMemoryMetric)

    /// Full decode memory baselines per format.
    /// These use Apple's XCTMemoryMetric which tracks peak physical memory
    /// during the measurement block, giving us reliable baselines over time.

    func testJPEGFullDecodeMemoryBaseline() {
        let source = makeSource(for: .jpeg)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    func testPNGFullDecodeMemoryBaseline() {
        let source = makeSource(for: .png)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    func testWebPFullDecodeMemoryBaseline() {
        let source = makeSource(for: .webp)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    func testAVIFFullDecodeMemoryBaseline() {
        let source = makeSource(for: .avif)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    func testJXLFullDecodeMemoryBaseline() {
        let source = makeSource(for: .jpegXL)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    func testHEICFullDecodeMemoryBaseline() {
        let source = makeSource(for: .heic)
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let _ = source.decodeFullCGImage()
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
