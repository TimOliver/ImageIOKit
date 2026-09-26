import XCTest
import UIKit
import jxl
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
private func sampleOperation<T>(_ operation: () throws -> T) rethrows -> (T, Double, UInt64, UInt64, Int) {
    let baseline = footprint(), state = Peak()
    let queue = DispatchQueue(label: "probe.memory")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    timer.setEventHandler { state.sample() }; timer.resume()
    defer { timer.cancel(); queue.sync {} }
    JXLProbe.resetAllocations()
    let start = CFAbsoluteTimeGetCurrent()
    let value = try operation()
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    state.sample(); timer.cancel(); queue.sync {}
    return (value, elapsed, baseline, state.maximum, JXLProbe.allocatedBytes)
}
private struct Configuration: Sendable {
    let name: String
    let resizable: Bool
    let threads: Int
    var legacy = false
    func apply() { JXLProbe.resizable = resizable; JXLProbe.threads = threads }
}
private let configurations = [
    Configuration(name: "legacy_default", resizable: false, threads: -1, legacy: true),
    Configuration(name: "direct_default", resizable: false, threads: -1),
    Configuration(name: "direct_resize3", resizable: true, threads: 3)
]
private func decode(_ data: Data, configuration: Configuration) throws -> PixelBuffer {
    let source = try XCTUnwrap(ImageSource(data: data))
    let bound = CGSize(width: 2048, height: 2048)
    if configuration.legacy {
        // Reproduce the old public JXL path, including the final extra render.
        let size = try SoftwareScaler.outputSize(for: source.imageSize, fitting: bound)
        return try source.render(source.thumbnailCGImage(fitting: size), size: size, pixelFormat: .rgba8)
    }
    return try source.decode(targetSize: bound)
}
private final class Batch: @unchecked Sendable {
    let inputs: [Data]
    let lock = NSLock()
    var buffers: [PixelBuffer] = []
    var latencies: [Double] = []
    var errors: [String] = []
    init(inputs: [Data]) { self.inputs = inputs }
}
final class MemoryTrackingTests: XCTestCase {
    private let pages = [0, 3, 56, 117, 12, 13]
    private func input(_ page: Int) throws -> Data {
        let name = page < 0 ? "large" : String(format: "page%03d", page)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jxl", subdirectory: "ProbeFixtures"))
        return try Data(contentsOf: url)
    }
    func test00AllocationBudget() throws {
        let data = try input(3)
        configurations[0].apply()
        let (legacy, _, _, _, legacyBytes) = try sampleOperation { try decode(data, configuration: configurations[0]) }
        let (direct, _, _, _, directBytes) = try sampleOperation { try decode(data, configuration: configurations[1]) }
        XCTAssertEqual(direct.width, 1440); XCTAssertEqual(direct.height, 2048)
        XCTAssertEqual(memcmp(legacy.data, direct.data, direct.dataSize), 0)
        XCTAssertLessThanOrEqual(directBytes, 2160 * 3072 * 4 + 1440 * 2048 * 4)
        print("LATENCY_ALLOCATION legacyBytes=\(legacyBytes) directBytes=\(directBytes) outputBytes=\(direct.dataSize)")
    }
    func test01SinglePageMatrix() throws {
        print("LATENCY_DEVICE version=\(JxlDecoderVersion()) defaultThreads=\(JxlThreadParallelRunnerDefaultNumWorkerThreads()) cores=\(ProcessInfo.processInfo.processorCount)")
        for (pageIndex, page) in pages.enumerated() {
            try autoreleasepool {
                let data = try input(page)
                configurations[0].apply()
                let reference = try decode(data, configuration: configurations[0])
                for iteration in 0..<5 {
                    for offset in configurations.indices {
                        let config = configurations[(offset + iteration + pageIndex) % configurations.count]
                        config.apply()
                        try autoreleasepool {
                            let (buffer, seconds, baseline, peak, allocated) = try sampleOperation { try decode(data, configuration: config) }
                            XCTAssertEqual(buffer.width, reference.width); XCTAssertEqual(buffer.height, reference.height)
                            XCTAssertEqual(memcmp(buffer.data, reference.data, buffer.dataSize), 0, "\(page) \(config.name)")
                            print("LATENCY_SINGLE config=\(config.name) page=\(page) iteration=\(iteration) seconds=\(seconds) baseline=\(baseline) peak=\(peak) allocatedBytes=\(allocated) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                        }
                    }
                }
            }
        }
        fflush(stdout)
    }
    func test02ConcurrentMatrix() throws {
        let inputs = try pages.map { try input($0) }
        for iteration in 0..<3 {
            for workers in (iteration % 2 == 0 ? [1, 2, 3] : [3, 2, 1]) {
                for offset in configurations.indices {
                    let config = configurations[(offset + iteration + workers) % configurations.count]
                    config.apply()
                    let state = Batch(inputs: inputs)
                    let (_, seconds, baseline, peak, allocated) = sampleOperation {
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            for index in stride(from: worker, to: inputs.count, by: workers) {
                                autoreleasepool {
                                    do {
                                        let start = CFAbsoluteTimeGetCurrent()
                                        let buffer = try decode(state.inputs[index], configuration: config)
                                        let elapsed = CFAbsoluteTimeGetCurrent() - start
                                        state.lock.lock(); state.buffers.append(buffer); state.latencies.append(elapsed); state.lock.unlock()
                                    } catch {
                                        state.lock.lock(); state.errors.append(String(describing: error)); state.lock.unlock()
                                    }
                                }
                            }
                        }
                    }
                    XCTAssertTrue(state.errors.isEmpty, "\(state.errors)"); XCTAssertEqual(state.buffers.count, 6)
                    let latency = state.latencies.reduce(0, +) / Double(state.latencies.count)
                    print("LATENCY_BATCH config=\(config.name) workers=\(workers) iteration=\(iteration) seconds=\(seconds) meanLatency=\(latency) baseline=\(baseline) peak=\(peak) allocatedBytes=\(allocated) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
            }
        }
        fflush(stdout)
    }
    func test03OversizedConfirmation() throws {
        let data = try input(-1)
        configurations[0].apply()
        let reference = try decode(data, configuration: configurations[0])
        for iteration in 0..<3 {
            for offset in configurations.indices {
                let config = configurations[(offset + iteration) % configurations.count]
                config.apply()
                try autoreleasepool {
                    let (buffer, seconds, baseline, peak, allocated) = try sampleOperation { try decode(data, configuration: config) }
                    XCTAssertEqual(buffer.width, reference.width); XCTAssertEqual(buffer.height, reference.height)
                    XCTAssertEqual(memcmp(buffer.data, reference.data, buffer.dataSize), 0, config.name)
                    print("LATENCY_LARGE config=\(config.name) iteration=\(iteration) seconds=\(seconds) baseline=\(baseline) peak=\(peak) allocatedBytes=\(allocated) width=\(buffer.width) height=\(buffer.height) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
            }
        }
        fflush(stdout)
    }

}
