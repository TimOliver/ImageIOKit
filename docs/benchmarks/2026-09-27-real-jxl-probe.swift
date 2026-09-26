import XCTest
import ImageIO
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
private final class BatchState: @unchecked Sendable {
    let lock = NSLock()
    var buffers: [PixelBuffer] = []
    var errors: [String] = []
    var latencies: [Double] = []
    let inputs: [Data]
    init(inputs: [Data]) { self.inputs = inputs }
}
final class MemoryTrackingTests: XCTestCase {
    private let pages = [0, 3, 56, 117, 12, 13]
    private func input(_ page: Int) throws -> Data {
        let name = String(format: "page%03d", page)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jxl", subdirectory: "ProbeFixtures"))
        return try Data(contentsOf: url)
    }
    func testRealJXLDecodeAndCache() throws {
        print("REAL_VERSION value=\(JxlDecoderVersion()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        for page in pages { try autoreleasepool { try benchmark(page) } }
    }
    private func benchmark(_ page: Int) throws {
        let data = try input(page)
        let (reference, firstTime, firstBase, firstPeak) = try sampleOperation {
            try XCTUnwrap(ImageSource(data: data)).decode(targetSize: CGSize(width: 2048, height: 2048))
        }
        let source = try XCTUnwrap(ImageSource(data: data))
        print("REAL_SOURCE version=\(JxlDecoderVersion()) page=\(page) inputBytes=\(data.count) sourceWidth=\(Int(source.imageSize.width)) sourceHeight=\(Int(source.imageSize.height)) width=\(reference.width) height=\(reference.height) firstSeconds=\(firstTime) firstBaseline=\(firstBase) firstPeak=\(firstPeak) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        for target in [2048, 1024] {
            for iteration in 0..<5 {
                try autoreleasepool {
                    let (buffer, seconds, base, peak) = try sampleOperation {
                        try XCTUnwrap(ImageSource(data: data)).decode(targetSize: CGSize(width: target, height: target))
                    }
                    XCTAssertLessThanOrEqual(max(buffer.width, buffer.height), target)
                    print("REAL_DECODE version=\(JxlDecoderVersion()) page=\(page) target=\(target) iteration=\(iteration) seconds=\(seconds) baseline=\(base) peak=\(peak) width=\(buffer.width) height=\(buffer.height) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
            }
        }
        let reconstructed = source.reconstructJPEGfromJPEGXL()
        print("REAL_RECONSTRUCTION page=\(page) bytes=\(reconstructed?.count ?? 0)")
        // Compare output of both native library builds through an attachment.
        let referenceImage = UIImage(cgImage: try XCTUnwrap(reference.makeCGImage()))
        let referenceAttachment = XCTAttachment(data: try XCTUnwrap(referenceImage.pngData()), uniformTypeIdentifier: "public.png")
        referenceAttachment.name = "reference-page\(page)-v\(JxlDecoderVersion())"; referenceAttachment.lifetime = .keepAlways; add(referenceAttachment)
        if JxlDecoderVersion() != 11002 { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for iteration in -1..<5 {
            let formats: [ImageFileFormat] = iteration % 2 == 0 ? [.png, .jpeg] : [.jpeg, .png]
            for format in formats {
                try autoreleasepool {
                    let url = directory.appendingPathComponent("\(format)-\(iteration).cache")
                    let (_, writeTime, writeBase, writePeak) = try sampleOperation { try reference.write(to: url, as: format) }
                    let (decoded, readTime, readBase, readPeak) = try sampleOperation { try XCTUnwrap(ImageSource(url: url)).decode() }
                    XCTAssertEqual(decoded.width, reference.width); XCTAssertEqual(decoded.height, reference.height)
                    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
                    if iteration >= 0 { print("REAL_CACHE page=\(page) format=\(format) iteration=\(iteration) bytes=\(bytes) writeSeconds=\(writeTime) readSeconds=\(readTime) writeBaseline=\(writeBase) writePeak=\(writePeak) readBaseline=\(readBase) readPeak=\(readPeak) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)") }
                    if iteration == 0 {
                        let a=reference.data.assumingMemoryBound(to: UInt8.self), b=decoded.data.assumingMemoryBound(to: UInt8.self)
                        var absolute=0.0, squared=0.0, maximum=0
                        for i in 0..<(reference.width*reference.height) { for c in 0..<3 {
                            let delta=abs(Int(a[i*4+c])-Int(b[i*4+c])); absolute += Double(delta); squared += Double(delta*delta); maximum=max(maximum,delta)
                        } }
                        let count=Double(reference.width*reference.height*3)
                        print("REAL_QUALITY page=\(page) format=\(format) meanAbsolute=\(absolute/count) maximum=\(maximum) psnr=\(squared == 0 ? "infinite" : String(10*log10(255*255/(squared/count))))")
                        if format == .png { XCTAssertEqual(maximum,0) }
                        let attachment=XCTAttachment(data:try Data(contentsOf:url),uniformTypeIdentifier:format == .png ? "public.png" : "public.jpeg")
                        attachment.name="cache-page\(page)-\(format)";attachment.lifetime = .keepAlways;add(attachment)
                    }
                }
            }
        }
        fflush(stdout)
    }
    func testRealJXLConcurrentBatches() throws {
        let inputs = try pages.map { try input($0) }
        for iteration in 0..<3 {
            for workers in (iteration % 2 == 0 ? [1,2,3] : [3,2,1]) {
                let state = BatchState(inputs: inputs)
                let (_, seconds, base, peak) = sampleOperation {
                    DispatchQueue.concurrentPerform(iterations: workers) { worker in
                        for index in stride(from: worker, to: state.inputs.count, by: workers) {
                            autoreleasepool {
                                do {
                                    let start=CFAbsoluteTimeGetCurrent()
                                    let buffer=try XCTUnwrap(ImageSource(data: state.inputs[index])).decode(targetSize: CGSize(width:2048,height:2048))
                                    let elapsed=CFAbsoluteTimeGetCurrent()-start
                                    state.lock.lock();state.buffers.append(buffer);state.latencies.append(elapsed);state.lock.unlock()
                                } catch {state.lock.lock();state.errors.append(String(describing:error));state.lock.unlock()}
                            }
                        }
                    }
                }
                XCTAssertTrue(state.errors.isEmpty,"\(state.errors)");XCTAssertEqual(state.buffers.count,6)
                let mean=state.latencies.reduce(0,+)/Double(state.latencies.count)
                print("REAL_BATCH version=\(JxlDecoderVersion()) workers=\(workers) iteration=\(iteration) pages=\(state.buffers.count) seconds=\(seconds) meanLatency=\(mean) baseline=\(base) peak=\(peak) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            }
        }
        fflush(stdout)
    }
}
