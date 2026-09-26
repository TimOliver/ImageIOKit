// Standalone device probe, excluded from the library/package test target.
// Copy into a temporary example test project. Add a ProbeFixtures folder resource
// containing page001.jpg, page015.jpg, page151.jpg, page170.jpg and page281.jpg
// from the private JPEG comic sample.
// Artwork is not included.
import XCTest
import ImageIO
import UIKit
import Darwin.Mach
@testable import ImageIOKitExample

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.phys_footprint
}
private final class Peak: @unchecked Sendable {
    let lock = NSLock()
    var maximum: UInt64 = 0
    func sample() { let value = footprint(); lock.lock(); maximum = max(maximum, value); lock.unlock() }
}
private func sampleOperation<T>(_ operation: () throws -> T) rethrows -> (T, Double, UInt64, UInt64) {
    let base = footprint(), state = Peak()
    let queue = DispatchQueue(label: "cache.memory")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    timer.setEventHandler { state.sample() }; timer.resume()
    defer { timer.cancel(); queue.sync {} }
    let start = CFAbsoluteTimeGetCurrent()
    let value = try operation()
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    state.sample()
    timer.cancel(); queue.sync {}
    return (value, elapsed, base, state.maximum)
}
final class MemoryTrackingTests: XCTestCase {
    func testDiskCacheBenchmark() throws {
        for page in [1, 15, 151, 170, 281] {
            try autoreleasepool { try benchmark(page: page) }
        }
    }
    private func benchmark(page: Int) throws {
        let name = String(format: "page%03d", page)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jpg", subdirectory: "ProbeFixtures"))
        let data = try Data(contentsOf: fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(ImageSource(data: data))
        let reference = try source.decode(targetSize: CGSize(width: 2048, height: 2048))
        print("CACHE_SOURCE page=\(page) sourceWidth=\(Int(source.imageSize.width)) sourceHeight=\(Int(source.imageSize.height)) inputBytes=\(data.count) width=\(reference.width) height=\(reference.height) bufferBytes=\(reference.dataSize) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        // Fresh source per iteration; compressed archive entry is already in memory.
        for iteration in 0..<5 {
            try autoreleasepool {
                let (buffer, seconds, base, peak) = try sampleOperation {
                    try XCTUnwrap(ImageSource(data: data)).decode(targetSize: CGSize(width: 2048, height: 2048))
                }
                XCTAssertEqual(buffer.width, reference.width)
                print("CACHE_ORIGINAL page=\(page) iteration=\(iteration) seconds=\(seconds) baseline=\(base) peak=\(peak)")
            }
        }
        // Alternate format order between iterations; iteration -1 warms both encoders.
        for iteration in -1..<7 {
            let formats: [ImageFileFormat] = iteration % 2 == 0 ? [.png, .jpeg] : [.jpeg, .png]
            for format in formats {
                try autoreleasepool {
                    let url = directory.appendingPathComponent("\(format)-\(iteration).cache")
                    let (_, writeTime, writeBase, writePeak) = try sampleOperation {
                        try reference.write(to: url, as: format, quality: 0.95)
                    }
                    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
                    let (decoded, readTime, readBase, readPeak) = try sampleOperation {
                        try XCTUnwrap(ImageSource(url: url)).decode()
                    }
                    XCTAssertEqual(decoded.width, reference.width)
                    XCTAssertEqual(decoded.height, reference.height)
                    let value = decoded.pixel(at: 0, y: 0)
                    if iteration >= 0 {
                        print("CACHE_RESULT page=\(page) format=\(format) iteration=\(iteration) bytes=\(bytes) writeSeconds=\(writeTime) readSeconds=\(readTime) writeBaseline=\(writeBase) writePeak=\(writePeak) readBaseline=\(readBase) readPeak=\(readPeak) first=\(value.r) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                    }
                    if iteration == 0 {
                        let a = reference.data.assumingMemoryBound(to: UInt8.self)
                        let b = decoded.data.assumingMemoryBound(to: UInt8.self)
                        var sum = 0.0, squared = 0.0, maximum = 0
                        for i in 0..<(reference.width * reference.height) {
                            for c in 0..<3 {
                                let difference = abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
                                sum += Double(difference); squared += Double(difference * difference)
                                maximum = max(maximum, difference)
                            }
                        }
                        let count = Double(reference.width * reference.height * 3)
                        let psnr = squared == 0 ? "infinite" : String(10 * log10(255 * 255 / (squared / count)))
                        print("CACHE_QUALITY page=\(page) format=\(format) meanAbsolute=\(sum/count) maximum=\(maximum) psnr=\(psnr)")
                        if format == .png { XCTAssertEqual(maximum, 0) }
                        let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: format == .png ? "public.png" : "public.jpeg")
                        attachment.name = "page\(page)-\(format)"; attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
        fflush(stdout)
    }
}

extension MemoryTrackingTests {
    func testJPEGQualitySweep() throws {
        for page in [1, 15, 151, 170, 281] {
            try autoreleasepool {
                let name = String(format: "page%03d", page)
                let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jpg", subdirectory: "ProbeFixtures"))
                let reference = try XCTUnwrap(ImageSource(url: fixture)).decode(targetSize: CGSize(width: 2048, height: 2048))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                for iteration in -1..<5 {
                    let qualities = iteration % 2 == 0 ? [0.85, 0.90, 0.95] : [0.95, 0.90, 0.85]
                    for quality in qualities {
                        try autoreleasepool {
                            let url = directory.appendingPathComponent("\(quality)-\(iteration).jpg")
                            let (_, writeTime, _, _) = try sampleOperation { try reference.write(to: url, as: .jpeg, quality: quality) }
                            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
                            let (decoded, readTime, _, _) = try sampleOperation { try XCTUnwrap(ImageSource(url: url)).decode() }
                            if iteration >= 0 {
                                print("SWEEP_RESULT page=\(page) quality=\(quality) iteration=\(iteration) bytes=\(bytes) writeSeconds=\(writeTime) readSeconds=\(readTime) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                            }
                            if iteration == 0 {
                                let a = reference.data.assumingMemoryBound(to: UInt8.self), b = decoded.data.assumingMemoryBound(to: UInt8.self)
                                var sum = 0.0, squared = 0.0, maximum = 0
                                for i in 0..<(reference.width * reference.height) {
                                    for c in 0..<3 {
                                        let difference = abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
                                        sum += Double(difference); squared += Double(difference * difference); maximum = max(maximum, difference)
                                    }
                                }
                                let count = Double(reference.width * reference.height * 3)
                                print("SWEEP_QUALITY page=\(page) quality=\(quality) meanAbsolute=\(sum/count) maximum=\(maximum) psnr=\(10 * log10(255 * 255 / (squared / count)))")
                                let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "public.jpeg")
                                attachment.name = "page\(page)-quality\(quality)"; attachment.lifetime = .keepAlways; add(attachment)
                            }
                        }
                    }
                }
                fflush(stdout)
            }
        }
    }
}
