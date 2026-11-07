import Foundation
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
@testable import ImageIOKit

// Mac TurboJPEG routing cutoff sweep (TASKS item 3).
//
// turboJPEGTextureSource routes JPEGs at or below a pixel-count cutoff to TurboJPEG on Mac
// and Catalyst; larger ones use ImageIO subsampling. This probe times the complete
// makeTexture pipeline with the routing pinned to each side through the
// ImageSource.benchmarkTurboJPEGCutoff switch that setup-mac.sh patches into the harness's
// library copy, over colour and gray pages from 6.6 to 50 MP. The two legs alternate inside
// every iteration so thermal drift on fanless machines lands on both sides evenly.
//
// Usage: CutoffSweep <fixtures-dir> [--targets=2752,1664] [--iterations=10]
// Missing sweep fixtures are generated into <fixtures-dir> on first run.

// MARK: - Fixtures (mirrors FixtureFactory in 2026-11-06-gpu-scale-probe.swift, JPEG only)

enum SweepFixtures {
    /// Procedural comic page in four panels, sized relative to a 2160 px wide reference
    /// so oversized fixtures look like higher-resolution scans of the same art:
    /// zone plate (aliasing), gradient (banding), line art (edges), screentone (moiré).
    /// Light grain keeps codec work realistic. Gray fixtures store one byte per pixel.
    static func pixels(width: Int, height: Int, gray: Bool) -> [UInt8] {
        let channels = gray ? 1 : 4
        let scale = Double(width) / 2160
        let halfW = width / 2, halfH = height / 2
        var bytes = [UInt8](repeating: 255, count: width * height * channels)
        bytes.withUnsafeMutableBytes { buffer in
            let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
            let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * channels, space: space, bitmapInfo: info)!
            // CG's origin is bottom-left: y >= halfH is the top of the page.
            let colors = [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1),
                          CGColor(srgbRed: 1.0, green: 0.6, blue: 0.2, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: nil)!
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: halfH, width: halfW, height: height - halfH))
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: halfH),
                                       end: CGPoint(x: halfW, y: height), options: [])
            context.restoreGState()
            // Line art: strokes from 0.5 to 8 reference pixels wide, plus concentric circles.
            context.setStrokeColor(gray: 0, alpha: 1)
            for i in 0..<40 {
                context.setLineWidth(CGFloat((0.5 + Double(i % 8)) * scale))
                let x = CGFloat(Double(i) * Double(halfW) / 40)
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x + CGFloat(halfW) / 3, y: CGFloat(halfH)))
                context.strokePath()
            }
            for r in stride(from: 10.0, to: 500.0, by: 23.0) {
                context.setLineWidth(CGFloat(1.5 * scale))
                context.strokeEllipse(in: CGRect(x: CGFloat(Double(halfW) / 2 - r * scale), y: CGFloat(Double(halfH) / 2 - r * scale),
                                                 width: CGFloat(2 * r * scale), height: CGFloat(2 * r * scale)))
            }
        }
        bytes.withUnsafeMutableBufferPointer { pixels in
            let radius = Double(min(halfW, halfH)) / scale
            var seed: UInt32 = 0x1234_5678
            for y in 0..<height {
                for x in 0..<width {
                    var value: Double?
                    if x >= halfW && y < halfH {
                        // Zone plate (top right): local frequency rises to 0.3 cycles per reference pixel.
                        let u = Double(x - halfW - halfW / 2), v = Double(y - halfH / 2)
                        let r2 = (u * u + v * v) / (scale * scale)
                        value = 0.5 + 0.5 * cos(Double.pi * 0.3 * r2 / radius)
                    } else if x >= halfW && y >= halfH {
                        // Screentone (bottom right): 8 reference px dots growing left to right.
                        let period = 8 * scale
                        let dx = Double(x).truncatingRemainder(dividingBy: period) - period / 2
                        let dy = Double(y).truncatingRemainder(dividingBy: period) - period / 2
                        let dotRadius = period * 0.5 * Double(x - halfW) / Double(width - halfW)
                        value = dx * dx + dy * dy < dotRadius * dotRadius ? 0 : 1
                    }
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let grain = Int(seed >> 29) - 4
                    let base = (y * width + x) * channels
                    for channel in 0..<(gray ? 1 : 3) {
                        let original = value.map { Int($0 * 255) } ?? Int(pixels[base + channel])
                        pixels[base + channel] = UInt8(clamping: original + grain)
                    }
                }
            }
        }
        return bytes
    }

    static func cgImage(_ pixels: [UInt8], width: Int, height: Int, gray: Bool) -> CGImage {
        let channels = gray ? 1 : 4
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                       bytesPerRow: width * channels, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func jpeg(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Sweep matrix: pages at 6.6, 8, 12, 16, 24, 36 and 50 MP, colour and gray.
    /// The gray 6.6 MP and colour 50 MP anchors reuse the 2026-11-06 fixtures byte for byte
    /// (the generator is deterministic), tying this sweep to the earlier write-ups.
    static let specs: [(name: String, gray: Bool, width: Int, height: Int)] = [
        ("manga-2160x3072-gray", true, 2160, 3072),
        ("sweep-2160x3072", false, 2160, 3072),
        ("sweep-2310x3464-gray", true, 2310, 3464),
        ("sweep-2310x3464", false, 2310, 3464),
        ("sweep-2828x4242-gray", true, 2828, 4242),
        ("sweep-2828x4242", false, 2828, 4242),
        ("sweep-3266x4898-gray", true, 3266, 4898),
        ("sweep-3266x4898", false, 3266, 4898),
        ("sweep-4000x6000-gray", true, 4000, 6000),
        ("sweep-4000x6000", false, 4000, 6000),
        ("sweep-4900x7348-gray", true, 4900, 7348),
        ("sweep-4900x7348", false, 4900, 7348),
        ("sweep-5000x10000-gray", true, 5000, 10000),
        ("page-5000x10000", false, 5000, 10000),
    ]

    static func load(directory: URL) throws -> [(name: String, gray: Bool, mp: Double, data: Data)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try specs.map { spec in
            let url = directory.appendingPathComponent("\(spec.name).jpeg")
            if !FileManager.default.fileExists(atPath: url.path) {
                print("GENERATE \(url.lastPathComponent)")
                let raw = pixels(width: spec.width, height: spec.height, gray: spec.gray)
                try jpeg(cgImage(raw, width: spec.width, height: spec.height, gray: spec.gray)).write(to: url)
            }
            return (spec.name, spec.gray, Double(spec.width * spec.height) / 1e6,
                    try Data(contentsOf: url))
        }
    }
}

// MARK: - Timing

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
}

func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

/// Times a fixed dependency-chained FP loop: a clock canary. Full-speed P cores measure the
/// same number every run, so a 2-3x slower calibration marks thermal throttling or a
/// background-QoS clamp onto efficiency cores, and the cells around it can't be trusted.
func calibrationMS() -> Double {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var x = 1.000000394
    for _ in 0..<20_000_000 { x = x * 1.0000001 + 0.0000001 }
    precondition(x > 1)
    return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
}

// CI VMs, Intel ones especially, can lack a Metal/MPS device; the sweep then times the
// CPU half of the pipeline (pinned decode plus render), the part the routing decision weighs.
let scaler = MTLCreateSystemDefaultDevice().flatMap { TextureScaler(device: $0) }

final class Call: @unchecked Sendable {
    let source: ImageSource, target: CGSize, format: PixelBuffer.PixelFormat, scaler: TextureScaler
    var texture: MTLTexture?, error: Error?
    init(_ source: ImageSource, _ target: CGSize, _ format: PixelBuffer.PixelFormat, _ scaler: TextureScaler) {
        self.source = source; self.target = target; self.format = format; self.scaler = scaler
    }
}

/// The complete pipeline: fresh ImageSource, makeTexture, GPU wait. Milliseconds.
/// Without a Metal/MPS device, times the pinned route's decode and render instead.
func makeTextureMS(_ data: Data, _ target: CGSize, _ format: PixelBuffer.PixelFormat) -> Double {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard let scaler else {
        let source = ImageSource(data: data)!
        let size = try! SoftwareScaler.outputSize(for: source.imageSize, fitting: target)
        precondition(try! source.nativeTextureSource(covering: size, targetSize: target,
                                                     pixelFormat: format) != nil,
                     "pinned route returned no buffer")
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
    }
    let call = Call(ImageSource(data: data)!, target, format, scaler)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { call.texture = try await call.source.makeTexture(fitting: call.target, pixelFormat: call.format, using: call.scaler) }
        catch { call.error = error }
        done.signal()
    }
    done.wait()
    let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
    if let error = call.error { fatalError("makeTexture failed: \(error)") }
    precondition(call.texture != nil)
    return elapsed
}

/// The pinned route's decoded, pre-resample size, for interpreting the timings.
func intermediate(_ data: Data, _ target: CGSize, _ format: PixelBuffer.PixelFormat) -> String {
    let source = ImageSource(data: data)!
    guard let size = try? SoftwareScaler.outputSize(for: source.imageSize, fitting: target),
          let buffer = try? source.nativeTextureSource(covering: size, targetSize: target, pixelFormat: format)
    else { return "none" }
    return "\(buffer.width)x\(buffer.height)"
}

// MARK: - Main

var directory: URL?
var targets: [Double] = [2752, 1664]
var iterations = 10
var only: String?
var cooldown = 1.0
for argument in CommandLine.arguments.dropFirst() {
    if argument.hasPrefix("--targets=") {
        targets = argument.dropFirst("--targets=".count).split(separator: ",").compactMap { Double($0) }
    } else if argument.hasPrefix("--iterations=") {
        iterations = Int(argument.dropFirst("--iterations=".count)) ?? iterations
    } else if argument.hasPrefix("--only=") {
        only = String(argument.dropFirst("--only=".count))
    } else if argument.hasPrefix("--sleep=") {
        cooldown = Double(argument.dropFirst("--sleep=".count)) ?? cooldown
    } else {
        directory = URL(fileURLWithPath: argument)
    }
}
guard let directory, !targets.isEmpty, iterations > 2 else {
    fatalError("Usage: CutoffSweep <fixtures-dir> [--targets=2752,1664] [--iterations=10 (min 3)] " +
               "[--only=substring] [--sleep=seconds]")
}

let fixtures = try SweepFixtures.load(directory: directory)

print("ENV mac=\(sysctlString("machdep.cpu.brand_string")) thermal=\(thermalName()) " +
      "calib=\(fmt(calibrationMS()))ms targets=\(targets.map { Int($0) }) iterations=\(iterations) " +
      "pipeline=\(scaler == nil ? "cpu-decode-only" : "makeTexture+GPU")")

// Self-check: the patched cutoff switch must actually flip the route.
do {
    let small = ImageSource(data: fixtures.first(where: { !$0.gray })!.data)!
    let probe = CGSize(width: 512, height: 512)
    ImageSource.benchmarkTurboJPEGCutoff = 0
    precondition(small.turboJPEGTextureSource(covering: probe, pixelFormat: .rgba8) == nil,
                 "cutoff 0 should disable TurboJPEG")
    ImageSource.benchmarkTurboJPEGCutoff = .greatestFiniteMagnitude
    precondition(small.turboJPEGTextureSource(covering: probe, pixelFormat: .rgba8) != nil,
                 "cutoff infinity should enable TurboJPEG")
}

for fixture in fixtures {
    if let only, !fixture.name.contains(only) { continue }
    print("\nFIXTURE \(fixture.name) mp=\(fmt(fixture.mp)) bytes=\(fixture.data.count) " +
          "calib=\(fmt(calibrationMS()))ms")
    for bound in targets {
        let target = CGSize(width: bound, height: bound)
        // Colour pages requested as gray8 never route to TurboJPEG, so only gray pages
        // sweep both formats.
        let formats: [PixelBuffer.PixelFormat] = fixture.gray ? [.gray8, .rgba8] : [.rgba8]
        for format in formats {
            Thread.sleep(forTimeInterval: cooldown)
            var turbo: [Double] = [], imageIO: [Double] = []
            for iteration in 0..<iterations {
                // Alternate which leg goes first so drift lands on both sides evenly.
                for isTurbo in iteration % 2 == 0 ? [true, false] : [false, true] {
                    ImageSource.benchmarkTurboJPEGCutoff = isTurbo ? .greatestFiniteMagnitude : 0
                    let time = makeTextureMS(fixture.data, target, format)
                    guard iteration > 1 else { continue }
                    if isTurbo { turbo.append(time) } else { imageIO.append(time) }
                }
            }
            ImageSource.benchmarkTurboJPEGCutoff = .greatestFiniteMagnitude
            let turboSource = intermediate(fixture.data, target, format)
            ImageSource.benchmarkTurboJPEGCutoff = 0
            let imageIOSource = intermediate(fixture.data, target, format)
            let t = median(turbo), i = median(imageIO)
            // Minimums are the throttle-resistant statistic on fanless machines; a median far
            // above its minimum marks a cell that ran hot.
            print("SWEEP fixture=\(fixture.name) mp=\(fmt(fixture.mp)) target=\(Int(bound)) format=\(format) " +
                  "turbo=\(fmt(t))ms imageio=\(fmt(i))ms ratio=\(fmt(t / i)) " +
                  "turboMin=\(fmt(turbo.min()!))ms imageioMin=\(fmt(imageIO.min()!))ms " +
                  "minRatio=\(fmt(turbo.min()! / imageIO.min()!)) " +
                  "turboSrc=\(turboSource) imageioSrc=\(imageIOSource) thermal=\(thermalName())")
        }
    }
}
print("BENCH-DONE")
