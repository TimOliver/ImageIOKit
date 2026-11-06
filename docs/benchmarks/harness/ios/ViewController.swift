//
//  GPU downscale benchmark for ImageIOKit.
//
//  Compares the shipped CPU pipeline (codec → CoreGraphics resample → texture upload)
//  with uploading the codec's native-scale output and resampling on the GPU via MPS.
//  Every timing starts from compressed Data in memory and ends with a ready MTLTexture.
//
//  Usage: GPUScaleBench <fixture-dir> [output-dir]
//

import Foundation
import UIKit
import CoreImage
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import Metal
import MetalPerformanceShaders
import UniformTypeIdentifiers
import jxl


// MARK: - Measurement

struct Stages {
    var decode = 0.0, scale = 0.0, upload = 0.0, gpu = 0.0
}

struct Sample {
    var wall: Double
    var cpu: Double
    var stages: Stages
}

func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func processCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
        : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

/// Runs `body` and returns its result plus elapsed milliseconds.
func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = uptime()
    let value = try body()
    return (value, ms(uptime() - start))
}

// MARK: - Fixtures

enum Codec: String { case jpeg, jxl }

struct Fixture {
    let name: String
    let codec: Codec
    let isGray: Bool
    let width: Int
    let height: Int
    let data: Data
}

enum FixtureFactory {
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

    /// VarDCT distance 1, effort 3: the settings used for the September fixtures.
    static func jxl(_ rgbaOrGray: [UInt8], width: Int, height: Int, gray: Bool) -> Data {
        let channels = gray ? 1 : 3
        var pixels = rgbaOrGray
        if !gray {
            pixels = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height) {
                pixels[i * 3] = rgbaOrGray[i * 4]
                pixels[i * 3 + 1] = rgbaOrGray[i * 4 + 1]
                pixels[i * 3 + 2] = rgbaOrGray[i * 4 + 2]
            }
        }
        let encoder = JxlEncoderCreate(nil)!
        defer { JxlEncoderDestroy(encoder) }
        let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        defer { JxlThreadParallelRunnerDestroy(runner) }
        precondition(JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner) == JXL_ENC_SUCCESS)
        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width); info.ysize = UInt32(height)
        info.bits_per_sample = 8; info.num_color_channels = UInt32(channels == 1 ? 1 : 3)
        info.uses_original_profile = 0
        precondition(JxlEncoderSetBasicInfo(encoder, &info) == JXL_ENC_SUCCESS)
        var color = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&color, gray ? 1 : 0)
        precondition(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS)
        let settings = JxlEncoderFrameSettingsCreate(encoder, nil)!
        precondition(JxlEncoderSetFrameDistance(settings, 1.0) == JXL_ENC_SUCCESS)
        precondition(JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) == JXL_ENC_SUCCESS)
        var format = JxlPixelFormat(num_channels: UInt32(channels), data_type: JXL_TYPE_UINT8,
                                    endianness: JXL_NATIVE_ENDIAN, align: 0)
        let added = pixels.withUnsafeBytes { JxlEncoderAddImageFrame(settings, &format, $0.baseAddress, $0.count) }
        precondition(added == JXL_ENC_SUCCESS)
        JxlEncoderCloseInput(encoder)

        var output = Data(count: 1 << 20)
        var written = 0
        while true {
            var status = JXL_ENC_ERROR
            output.withUnsafeMutableBytes { buffer in
                var next: UnsafeMutablePointer<UInt8>? =
                    buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: written)
                var available = buffer.count - written
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                written = buffer.count - available
            }
            if status == JXL_ENC_NEED_MORE_OUTPUT { output.count *= 2; continue }
            precondition(status == JXL_ENC_SUCCESS)
            break
        }
        output.count = written
        return output
    }

    /// Loads cached fixtures, generating any that are missing.
    static func all(directory: URL) throws -> [Fixture] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let specs: [(String, Codec, Bool, Int, Int)] = [
            ("photo-11000x11000", .jpeg, false, 11000, 11000),
            ("photo-11000x11000", .jxl, false, 11000, 11000),
            ("page-5000x10000", .jpeg, false, 5000, 10000),
            ("manga-2160x3072-gray", .jpeg, true, 2160, 3072),
            ("manga-2160x3072-gray", .jxl, true, 2160, 3072),
        ]
        var fixtures: [Fixture] = []
        for (name, codec, gray, width, height) in specs {
            let url = directory.appendingPathComponent("\(name).\(codec.rawValue)")
            if !FileManager.default.fileExists(atPath: url.path) {
                print("GENERATE \(url.lastPathComponent)")
                let raw = pixels(width: width, height: height, gray: gray)
                let data = codec == .jpeg
                    ? jpeg(cgImage(raw, width: width, height: height, gray: gray))
                    : jxl(raw, width: width, height: height, gray: gray)
                try data.write(to: url)
            }
            let data = try Data(contentsOf: url)
            fixtures.append(Fixture(name: "\(name).\(codec.rawValue)", codec: codec, isGray: gray,
                                    width: width, height: height, data: data))
        }
        return fixtures
    }
}

// MARK: - Ground truth

/// Exact area-average downscale of uncompressed pixels, in the same gamma-encoded space
/// CG and MPS resample in. Returns `colorChannels` floats per output pixel.
func areaAverage(_ source: [UInt8], width: Int, height: Int, channels: Int,
                 outWidth: Int, outHeight: Int) -> (values: [Float], channels: Int) {
    let color = channels == 4 ? 3 : 1
    let sx = Double(width) / Double(outWidth), sy = Double(height) / Double(outHeight)
    var output = [Double](repeating: 0, count: outWidth * outHeight * color)
    var row = [Double](repeating: 0, count: outWidth * color)
    for y in 0..<height {
        // Horizontal pass for this source row.
        for i in 0..<row.count { row[i] = 0 }
        for ox in 0..<outWidth {
            let start = Double(ox) * sx, end = start + sx
            var x = Int(start)
            while Double(x) < end && x < width {
                let weight = min(end, Double(x + 1)) - max(start, Double(x))
                for c in 0..<color { row[ox * color + c] += weight * Double(source[(y * width + x) * channels + c]) }
                x += 1
            }
        }
        // Vertical: source row y covers [y, y + 1), overlapping at most two output rows.
        let first = Int(Double(y) / sy), last = min(outHeight - 1, Int((Double(y + 1) - 1e-9) / sy))
        for oy in first...last {
            let weight = min(Double(y + 1), Double(oy + 1) * sy) - max(Double(y), Double(oy) * sy)
            guard weight > 0 else { continue }
            for i in 0..<row.count { output[oy * outWidth * color + i] += weight * row[i] }
        }
    }
    let area = sx * sy
    return (output.map { Float($0 / area) }, color)
}

/// PSNR of a readback against the ground truth, over color channels only.
/// RGBA readbacks of gray fixtures compare their red channel.
func truthPSNR(truth: (values: [Float], channels: Int), _ readback: (bytes: [UInt8], channels: Int)) -> Double {
    let pixels = truth.values.count / truth.channels
    guard readback.bytes.count / readback.channels == pixels else { return .nan }
    var squared = 0.0
    for pixel in 0..<pixels {
        for c in 0..<truth.channels {
            let d = Double(truth.values[pixel * truth.channels + c]) - Double(readback.bytes[pixel * readback.channels + c])
            squared += d * d
        }
    }
    let mse = squared / Double(truth.values.count)
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}

// MARK: - Pipelines

final class Bench {
    nonisolated(unsafe) private static var scaler: TextureScaler?
    static func sharedScaler(_ device: MTLDevice) -> TextureScaler {
        if let scaler { return scaler }
        let made = TextureScaler(device: device)!
        scaler = made
        return made
    }

    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    // Kernels are created once, as a reader would keep them for its lifetime.
    lazy var lanczos: MPSImageLanczosScale = {
        let kernel = MPSImageLanczosScale(device: device)
        kernel.edgeMode = .clamp
        return kernel
    }()
    lazy var bilinear: MPSImageBilinearScale = {
        let kernel = MPSImageBilinearScale(device: device)
        kernel.edgeMode = .clamp
        return kernel
    }()
    lazy var scaler = TextureScaler(device: device)!
    let iterations = 7
    let outputDirectory: URL?

    init(outputDirectory: URL?) { self.outputDirectory = outputDirectory }

    struct Pipeline {
        let name: String
        let run: (Fixture, CGSize) throws -> (MTLTexture, Stages)
    }

    func pipelines(for fixture: Fixture) -> [Pipeline] {
        var list = [
            Pipeline(name: "current") { f, target in try self.current(f, target, .rgba8) },
            Pipeline(name: "native+CG") { f, target in try self.nativeCG(f, target, gray: false) },
            Pipeline(name: "native+lanczos") { f, target in try self.nativeGPU(f, target, self.lanczos, gray: false) },
            Pipeline(name: "native+bilinear") { f, target in try self.nativeGPU(f, target, self.bilinear, gray: false) },
        ]
        list.append(Pipeline(name: "makeTexture") { f, target in try self.textureAPI(f, target, .rgba8) })
        if fixture.isGray {
            list.append(Pipeline(name: "makeTexture-gray8") { f, target in try self.textureAPI(f, target, .gray8) })
        }
        if fixture.codec == .jpeg {
            list.append(Pipeline(name: "coreimage") { f, target in try self.coreImage(f, target, gray: false) })
            if fixture.isGray {
                list.append(Pipeline(name: "coreimage-r8") { f, target in try self.coreImage(f, target, gray: true) })
            }
            list.append(Pipeline(name: "imageio-subsample+lanczos") { f, target in try self.imageIOSubsampleGPU(f, target) })
        }
        if fixture.isGray {
            list.append(Pipeline(name: "current-gray8") { f, target in try self.current(f, target, .gray8) })
            if fixture.codec == .jxl {
                list.append(Pipeline(name: "native-gray+CG") { f, target in try self.nativeCG(f, target, gray: true) })
                list.append(Pipeline(name: "native-gray+lanczos") { f, target in
                    try self.nativeGPU(f, target, self.lanczos, gray: true)
                })
            }
        }
        return list
    }

    /// The shipped path: `ImageSource.decode(targetSize:)`, then `makeTexture(device:)`.
    func current(_ fixture: Fixture, _ target: CGSize,
                 _ format: PixelBuffer.PixelFormat) throws -> (MTLTexture, Stages) {
        var stages = Stages()
        let (buffer, decode) = try timed {
            try ImageSource(data: fixture.data)!.decode(targetSize: target, pixelFormat: format)
        }
        let (texture, upload) = timed { buffer.makeTexture(device: device)! }
        stages.decode = decode; stages.upload = upload
        return (texture, stages)
    }

    /// The public API, `ImageSource.makeTexture(fitting:pixelFormat:using:)`, awaited synchronously.
    /// Its whole cost (decode, upload, GPU resample and completion) is reported as decode.
    func textureAPI(_ fixture: Fixture, _ target: CGSize,
                    _ format: PixelBuffer.PixelFormat) throws -> (MTLTexture, Stages) {
        final class Call: @unchecked Sendable {
            let source: ImageSource, scaler: TextureScaler, target: CGSize, format: PixelBuffer.PixelFormat
            var texture: MTLTexture?, error: Error?
            init(_ source: ImageSource, _ scaler: TextureScaler, _ target: CGSize, _ format: PixelBuffer.PixelFormat) {
                self.source = source; self.scaler = scaler; self.target = target; self.format = format
            }
        }
        var stages = Stages()
        let (call, total) = timed { () -> Call in
            let call = Call(ImageSource(data: fixture.data)!, scaler, target, format)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do { call.texture = try await call.source.makeTexture(fitting: call.target, pixelFormat: call.format,
                                                                     using: call.scaler) }
                catch { call.error = error }
                done.signal()
            }
            done.wait()
            return call
        }
        if let error = call.error { throw error }
        stages.decode = total
        return (call.texture!, stages)
    }

    /// Codec-native reduced decode: TurboJPEG DCT scaling or JXL DC/box-filtered output.
    func nativeDecode(_ fixture: Fixture, size: CGSize, gray: Bool) throws -> PixelBuffer {
        switch fixture.codec {
        case .jpeg:
            let decoder = JPEGRegionDecoder(data: fixture.data)!
            return try decoder.decodeRegion(
                cropRect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height), targetSize: size)
        case .jxl:
            return try JXLDecoder(data: fixture.data)!.decodeThumbnail(fittingSize: size, prefersGrayscale: gray)
        }
    }

    func outputSize(_ fixture: Fixture, _ target: CGSize) throws -> CGSize {
        try SoftwareScaler.outputSize(for: CGSize(width: fixture.width, height: fixture.height), fitting: target)
    }

    /// Same native decode as the GPU pipelines, but resampled by CoreGraphics as the library does.
    func nativeCG(_ fixture: Fixture, _ target: CGSize, gray: Bool) throws -> (MTLTexture, Stages) {
        var stages = Stages()
        let size = try outputSize(fixture, target)
        let (native, decode) = try timed { try nativeDecode(fixture, size: size, gray: gray) }
        let format: PixelBuffer.PixelFormat = gray ? .gray8 : .rgba8
        let (scaled, scale) = timed { () -> PixelBuffer in
            let output = PixelBuffer(width: Int(size.width), height: Int(size.height), pixelFormat: format)
            let alpha: CGImageAlphaInfo = gray ? .none : .premultipliedLast
            let context = CGContext(data: output.data, width: output.width, height: output.height,
                                    bitsPerComponent: 8, bytesPerRow: output.bytesPerRow,
                                    space: output.colorSpace, bitmapInfo: alpha.rawValue)!
            context.interpolationQuality = .high
            context.draw(native.makeCGImage()!, in: CGRect(origin: .zero, size: size))
            return output
        }
        let (texture, upload) = timed { scaled.makeTexture(device: device)! }
        stages.decode = decode; stages.scale = scale; stages.upload = upload
        return (texture, stages)
    }

    /// Uploads native-scale pixels and resamples them on the GPU into a private texture.
    func nativeGPU(_ fixture: Fixture, _ target: CGSize, _ kernel: MPSImageScale,
                   gray: Bool) throws -> (MTLTexture, Stages) {
        var stages = Stages()
        let size = try outputSize(fixture, target)
        let (native, decode) = try timed { try nativeDecode(fixture, size: size, gray: gray) }
        let (source, upload) = timed { native.makeTexture(device: device)! }
        let (destination, scale, gpu) = scaleOnGPU(source, size: size, kernel: kernel)
        stages.decode = decode; stages.upload = upload
        stages.scale = scale; stages.gpu = gpu
        return (destination, stages)
    }

    /// ImageIO JPEG decode at a 1/2, 1/4 or 1/8 subsample factor (no ImageIO resampling),
    /// uploaded as-is and resampled on the GPU. Falls back to a CG copy for unexpected layouts.
    func imageIOSubsampleGPU(_ fixture: Fixture, _ target: CGSize) throws -> (MTLTexture, Stages) {
        var stages = Stages()
        let size = try outputSize(fixture, target)
        let outWidth = Int(size.width), outHeight = Int(size.height)
        let factor: Int = [8, 4, 2].first { (factor: Int) -> Bool in
            let width: Int = (fixture.width + factor - 1) / factor
            let height: Int = (fixture.height + factor - 1) / factor
            return width >= outWidth && height >= outHeight
        } ?? 1
        let (image, decode) = timed { () -> CGImage in
            let source = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: factor,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
        }
        let (texture, upload) = timed { () -> MTLTexture in
            let alpha = image.alphaInfo, order = image.bitmapInfo.intersection(.byteOrderMask)
            let format: MTLPixelFormat?
            switch (image.bitsPerPixel, alpha, order) {
            case (32, .noneSkipLast, []), (32, .premultipliedLast, []), (32, .noneSkipLast, .byteOrder32Big),
                 (32, .premultipliedLast, .byteOrder32Big): format = .rgba8Unorm
            case (32, .noneSkipFirst, .byteOrder32Little), (32, .premultipliedFirst, .byteOrder32Little):
                format = .bgra8Unorm
            case (8, .none, _): format = .r8Unorm
            default: format = nil
            }
            if let format, let data = image.dataProvider?.data {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: image.width, height: image.height, mipmapped: false)
                descriptor.storageMode = .shared
                let texture = device.makeTexture(descriptor: descriptor)!
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                withBytes: CFDataGetBytePtr(data), bytesPerRow: image.bytesPerRow)
                return texture
            }
            print("NOTE unexpected ImageIO layout bpp=\(image.bitsPerPixel) alpha=\(alpha.rawValue) order=\(order.rawValue)")
            let buffer = PixelBuffer(width: image.width, height: image.height, pixelFormat: .rgba8)
            let context = CGContext(data: buffer.data, width: buffer.width, height: buffer.height, bitsPerComponent: 8,
                                    bytesPerRow: buffer.bytesPerRow, space: buffer.colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buffer.makeTexture(device: device)!
        }
        let (destination, scale, gpu) = scaleOnGPU(texture, size: size, kernel: lanczos)
        stages.decode = decode; stages.upload = upload; stages.scale = scale; stages.gpu = gpu
        return (destination, stages)
    }

    lazy var ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    /// ImageIO subsampled JPEG wrapped by Core Image, Lanczos-scaled on the GPU and rendered into a
    /// private texture. Edges are clamped before scaling so borders stay opaque. No color management.
    func coreImage(_ fixture: Fixture, _ target: CGSize, gray: Bool) throws -> (MTLTexture, Stages) {
        var stages = Stages()
        let size = try outputSize(fixture, target)
        let outWidth = Int(size.width), outHeight = Int(size.height)
        let factor: Int = [8, 4, 2].first { (factor: Int) -> Bool in
            fixture.width / factor >= outWidth && fixture.height / factor >= outHeight
        } ?? 1
        let (texture, total) = timed { () -> MTLTexture in
            let source = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: factor] as CFDictionary)!
            let scaleY = Double(outHeight) / Double(image.height)
            let aspect = (Double(outWidth) / Double(image.width)) / scaleY
            let input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            let scaled = input.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: aspect])
                .cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gray ? .r8Unorm : .rgba8Unorm,
                width: outWidth, height: outHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            let texture = device.makeTexture(descriptor: descriptor)!
            let commandBuffer = queue.makeCommandBuffer()!
            // Core Image's origin is bottom-left; flip so row 0 is the top, matching Metal.
            let flipped = scaled.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -Double(outHeight)))
            ciContext.render(flipped, to: texture, commandBuffer: commandBuffer,
                             bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return texture
        }
        stages.decode = total
        return (texture, stages)
    }

    /// Resamples into a new private texture of `size`; returns wall and GPU milliseconds.
    func scaleOnGPU(_ source: MTLTexture, size: CGSize, kernel: MPSImageScale) -> (MTLTexture, Double, Double) {
        let ((texture, gpu), wall) = timed { () -> (MTLTexture, Double) in
            // r8 sources keep r8; BGRA sources write RGBA so readback stays uniform.
            let format: MTLPixelFormat = source.pixelFormat == .r8Unorm ? .r8Unorm : .rgba8Unorm
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            let destination = device.makeTexture(descriptor: descriptor)!
            let commandBuffer = queue.makeCommandBuffer()!
            kernel.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            precondition(commandBuffer.status == .completed, "GPU scale failed: \(String(describing: commandBuffer.error))")
            return (destination, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        return (texture, wall, gpu)
    }

    // MARK: Quality

    /// Copies any texture's pixels to the CPU, blitting private textures through a shared one.
    func readBack(_ texture: MTLTexture) -> (bytes: [UInt8], channels: Int) {
        let channels = texture.pixelFormat == .r8Unorm ? 1 : 4
        var readable = texture
        if texture.storageMode == .private {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            descriptor.storageMode = .shared
            readable = device.makeTexture(descriptor: descriptor)!
            let commandBuffer = queue.makeCommandBuffer()!
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(from: texture, to: readable)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * channels)
        bytes.withUnsafeMutableBytes {
            readable.getBytes($0.baseAddress!, bytesPerRow: texture.width * channels,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (bytes, channels)
    }

    /// PSNR over color channels (alpha excluded) between two same-sized readbacks.
    func psnr(_ a: (bytes: [UInt8], channels: Int), _ b: (bytes: [UInt8], channels: Int)) -> Double {
        guard a.channels == b.channels, a.bytes.count == b.bytes.count else { return .nan }
        let colorChannels = a.channels == 4 ? 3 : 1
        var squared = 0.0, count = 0
        for pixel in 0..<(a.bytes.count / a.channels) {
            for channel in 0..<colorChannels {
                let difference = Double(a.bytes[pixel * a.channels + channel]) - Double(b.bytes[pixel * b.channels + channel])
                squared += difference * difference
                count += 1
            }
        }
        let mse = squared / Double(count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    func writePNG(_ readback: (bytes: [UInt8], channels: Int), width: Int, height: Int, name: String) {
        guard let outputDirectory else { return }
        let gray = readback.channels == 1
        let image = FixtureFactory.cgImage(readback.bytes, width: width, height: height, gray: gray)
        let url = outputDirectory.appendingPathComponent("\(name).png") as CFURL
        let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Run

    func run(fixtures: [Fixture], targets: [Int]) throws {
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        for fixture in fixtures {
            for bound in targets {
                let target = CGSize(width: bound, height: bound)
                let size = try outputSize(fixture, target)
                let nativeSize = try autoreleasepool {
                    let buffer = try nativeDecode(fixture, size: size, gray: false)
                    return "\(buffer.width)x\(buffer.height)"
                }
                print("\nCASE fixture=\(fixture.name) bytes=\(fixture.data.count) target=\(bound) " +
                      "output=\(Int(size.width))x\(Int(size.height)) native=\(nativeSize) " +
                      "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                let raw = FixtureFactory.pixels(width: fixture.width, height: fixture.height, gray: fixture.isGray)
                let truth = areaAverage(raw, width: fixture.width, height: fixture.height,
                                        channels: fixture.isGray ? 1 : 4,
                                        outWidth: Int(size.width), outHeight: Int(size.height))
                print("| Pipeline | Wall ms | CPU ms | Decode | Scale | Upload | GPU | PSNR vs current | PSNR vs truth |")
                print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")

                var references: [Int: (bytes: [UInt8], channels: Int)] = [:]
                for pipeline in pipelines(for: fixture) {
                    // Untimed warm-up also provides the quality readback.
                    let readback = try autoreleasepool { () -> (bytes: [UInt8], channels: Int) in
                        let (texture, _) = try pipeline.run(fixture, target)
                        precondition(texture.width == Int(size.width) && texture.height == Int(size.height))
                        let readback = readBack(texture)
                        writePNG(readback, width: texture.width, height: texture.height,
                                 name: "\(fixture.name)-\(bound)-\(pipeline.name)")
                        return readback
                    }
                    if pipeline.name.hasPrefix("current") { references[readback.channels] = readback }
                    let quality = references[readback.channels].map { psnr($0, readback) } ?? .nan

                    var samples: [Sample] = []
                    for _ in 0..<iterations {
                        try autoreleasepool {
                            let wallStart = uptime(), cpuStart = processCPU()
                            let (_, stages) = try pipeline.run(fixture, target)
                            samples.append(Sample(wall: ms(uptime() - wallStart),
                                                  cpu: ms(processCPU() - cpuStart), stages: stages))
                        }
                    }
                    let m = { (key: (Sample) -> Double) in median(samples.map(key)) }
                    let row = [m { $0.wall }, m { $0.cpu }, m { $0.stages.decode }, m { $0.stages.scale },
                               m { $0.stages.upload }, m { $0.stages.gpu }]
                        .map { String(format: "%.1f", $0) }
                    let format = { (value: Double) in value.isInfinite ? "∞" : String(format: "%.1f", value) }
                    let qualityText = pipeline.name.hasPrefix("current") ? "ref" : format(quality)
                    let truthText = format(truthPSNR(truth: truth, readback))
                    print("| \(pipeline.name) | " + row.joined(separator: " | ") + " | \(qualityText) | \(truthText) |")
                    let walls = samples.map { String(format: "%.2f", $0.wall) }.joined(separator: ",")
                    print("RAW fixture=\(fixture.name) target=\(bound) pipeline=\(pipeline.name) wall=[\(walls)] " +
                          "cpu=[\(samples.map { String(format: "%.2f", $0.cpu) }.joined(separator: ","))]")
                }
            }
        }
    }
}


// MARK: - ImageIO layout diagnostics

enum Diagnostics {
    static func run(fixtures: [Fixture], device: MTLDevice) throws {
        let ms = { (start: UInt64) in Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6 }
        let now = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        for fixture in fixtures where fixture.codec == .jpeg {
            for bound in [2048, 1024] {
                let size = try SoftwareScaler.outputSize(for: CGSize(width: fixture.width, height: fixture.height),
                                                         fitting: CGSize(width: bound, height: bound))
                let factor = [8, 4, 2, 1].first { (f: Int) -> Bool in
                    fixture.width / f >= Int(size.width) && fixture.height / f >= Int(size.height)
                } ?? 1
                var decode = [Double](), access = [Double](), render = [Double](), upload = [Double](), direct = [Double]()
                var line = ""
                for iteration in 0..<6 {
                    try autoreleasepool {
                        let source = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
                        var t = now()
                        let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: factor,
                            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
                        decode.append(ms(t))
                        t = now()
                        let data = image.dataProvider!.data!
                        access.append(ms(t))
                        let bytes = CFDataGetBytePtr(data)!
                        let gray = image.bitsPerPixel == 8
                        let format: PixelBuffer.PixelFormat = gray ? .gray8 : .rgba8
                        t = now()
                        let rendered = try ImageSource(data: fixture.data)!.render(image,
                            size: CGSize(width: image.width, height: image.height), pixelFormat: format)
                        render.append(ms(t))
                        t = now()
                        _ = rendered.makeTexture(device: device)
                        upload.append(ms(t))
                        // Direct upload of ImageIO's own bytes.
                        t = now()
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gray ? .r8Unorm : .rgba8Unorm,
                            width: image.width, height: image.height, mipmapped: false)
                        let texture = device.makeTexture(descriptor: descriptor)!
                        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                        withBytes: bytes, bytesPerRow: image.bytesPerRow)
                        direct.append(ms(t))
                        guard iteration == 0 else { return }
                        // Layout, alignment, and whether skipping CG's copy changes any values.
                        var alphaNot255 = 0
                        var maxDiff = 0
                        let channels = gray ? 1 : 4
                        let rows = min(image.height, 256)
                        let out = rendered.data.assumingMemoryBound(to: UInt8.self)
                        for y in 0..<rows {
                            for x in 0..<image.width {
                                let s = y * image.bytesPerRow + x * channels
                                let d = y * rendered.bytesPerRow + x * channels
                                if !gray && bytes[s + 3] != 255 { alphaNot255 += 1 }
                                for c in 0..<(gray ? 1 : 3) { maxDiff = max(maxDiff, abs(Int(bytes[s + c]) - Int(out[d + c]))) }
                            }
                        }
                        let page = Int(getpagesize())
                        let linear = device.minimumLinearTextureAlignment(for: gray ? .r8Unorm : .rgba8Unorm)
                        line = "LAYOUT fixture=\(fixture.name) bound=\(bound) factor=\(factor) image=\(image.width)x\(image.height) " +
                            "bpp=\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) order=\(image.bitmapInfo.intersection(.byteOrderMask).rawValue) " +
                            "space=\(image.colorSpace?.name as String? ?? "nil") bpr=\(image.bytesPerRow) dataLen=\(CFDataGetLength(data)) " +
                            "ptrPageAligned=\(Int(bitPattern: bytes) % page == 0) bprMod64=\(image.bytesPerRow % 64) linearAlign=\(linear) " +
                            "alphaNot255=\(alphaNot255) maxDiffVsCG=\(maxDiff)"
                    }
                }
                let med = { (v: [Double]) in String(format: "%.1f", v.sorted()[v.count / 2]) }
                print(line)
                print("STAGES fixture=\(fixture.name) bound=\(bound) decode=\(med(decode)) dataAccess=\(med(access)) " +
                      "cgRender=\(med(render)) uploadRendered=\(med(upload)) uploadDirect=\(med(direct))")
            }
        }
    }
}


// MARK: - Copy-avoidance experiments

enum Experiments {
    static func run(fixtures: [Fixture], device: MTLDevice) throws {
        let now = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        let ms = { (start: UInt64) in Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6 }
        let queue = device.makeCommandQueue()!
        let lanczos = MPSImageLanczosScale(device: device)
        lanczos.edgeMode = .clamp
        let ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

        func readAlpha(_ texture: MTLTexture) -> UInt8 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                             height: texture.height, mipmapped: false)
            d.storageMode = .shared
            let shared = device.makeTexture(descriptor: d)!
            let cb = queue.makeCommandBuffer()!
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: texture, to: shared); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 4)
            shared.getBytes(&px, bytesPerRow: 4 * texture.width, from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0)
            return px[3]
        }

        // 1. Does MPS honour a swizzled view that forces alpha to one?
        do {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            d.usage = [.shaderRead, .pixelFormatView]
            let src = device.makeTexture(descriptor: d)!
            let zeros = [UInt8](repeating: 0, count: 64 * 64 * 4)
            src.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: zeros, bytesPerRow: 256)
            let view = src.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1,
                swizzle: MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one))!
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
            dd.usage = [.shaderRead, .shaderWrite]; dd.storageMode = .private
            let dst = device.makeTexture(descriptor: dd)!
            let cb = queue.makeCommandBuffer()!
            lanczos.encode(commandBuffer: cb, sourceTexture: view, destinationTexture: dst)
            cb.commit(); cb.waitUntilCompleted()
            print("SWIZZLE alphaAfterLanczos=\(readAlpha(dst)) (255 means MPS honours the swizzle)")
        }

        for fixture in fixtures where fixture.codec == .jpeg {
            for bound in [2048, 1024] {
                let size = try SoftwareScaler.outputSize(for: CGSize(width: fixture.width, height: fixture.height),
                                                         fitting: CGSize(width: bound, height: bound))
                let factor = [8, 4, 2, 1].first { (f: Int) -> Bool in
                    fixture.width / f >= Int(size.width) && fixture.height / f >= Int(size.height)
                } ?? 1
                var direct = [Double](), core = [Double](), shipped = [Double]()
                var grayNote = ""
                for iteration in 0..<7 {
                    try autoreleasepool {
                        // Shipped makeTexture, for reference.
                        var t = now()
                        let source = ImageSource(data: fixture.data)!
                        let done = DispatchSemaphore(value: 0)
                        final class Box: @unchecked Sendable { var s: ImageSource?; var sc: TextureScaler?; var sz = CGSize.zero }
                        let box = Box(); box.s = source; box.sc = Bench.sharedScaler(device); box.sz = CGSize(width: bound, height: bound)
                        Task.detached { _ = try? await box.s!.makeTexture(fitting: box.sz, using: box.sc!); done.signal() }
                        done.wait()
                        shipped.append(ms(t))

                        // Direct: ImageIO bytes copied once into a texture, then Lanczos.
                        t = now()
                        let isrc = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
                        let image = CGImageSourceCreateImageAtIndex(isrc, 0, [kCGImageSourceSubsampleFactor: factor,
                            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
                        let data = image.dataProvider!.data!
                        let gray = image.bitsPerPixel == 8
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gray ? .r8Unorm : .rgba8Unorm,
                            width: image.width, height: image.height, mipmapped: false)
                        d.usage = [.shaderRead, .pixelFormatView]
                        let tex = device.makeTexture(descriptor: d)!
                        tex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                    withBytes: CFDataGetBytePtr(data)!, bytesPerRow: image.bytesPerRow)
                        let src: MTLTexture = gray ? tex : tex.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D,
                            levels: 0..<1, slices: 0..<1, swizzle: MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one))!
                        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gray ? .r8Unorm : .rgba8Unorm,
                            width: Int(size.width), height: Int(size.height), mipmapped: false)
                        dd.usage = [.shaderRead, .shaderWrite]; dd.storageMode = .private
                        let dst = device.makeTexture(descriptor: dd)!
                        let cb = queue.makeCommandBuffer()!
                        lanczos.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
                        cb.commit(); cb.waitUntilCompleted()
                        direct.append(ms(t))

                        // Core Image: wrap the subsampled CGImage, Lanczos on GPU, render into a texture.
                        t = now()
                        let isrc2 = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
                        let image2 = CGImageSourceCreateImageAtIndex(isrc2, 0, [kCGImageSourceSubsampleFactor: factor] as CFDictionary)!
                        let scale = Double(size.height) / Double(image2.height)
                        let ci = CIImage(cgImage: image2, options: [.colorSpace: NSNull()])
                            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                                kCIInputAspectRatioKey: (Double(size.width) / Double(image2.width)) / scale])
                        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                            width: Int(size.width), height: Int(size.height), mipmapped: false)
                        cd.usage = [.shaderRead, .shaderWrite]; cd.storageMode = .private
                        let ctex = device.makeTexture(descriptor: cd)!
                        let ccb = queue.makeCommandBuffer()!
                        ciContext.render(ci, to: ctex, commandBuffer: ccb,
                                         bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        ccb.commit(); ccb.waitUntilCompleted()
                        core.append(ms(t))

                        if iteration == 0 && gray {
                            // Would expanding gray to RGB by replication match CG's gray -> sRGB conversion?
                            let rgba = try source.render(image, size: CGSize(width: image.width, height: image.height), pixelFormat: .rgba8)
                            let raw = CFDataGetBytePtr(data)!
                            let out = rgba.data.assumingMemoryBound(to: UInt8.self)
                            var maxDiff = 0
                            for y in stride(from: 0, to: image.height, by: 7) {
                                for x in stride(from: 0, to: image.width, by: 7) {
                                    maxDiff = max(maxDiff, abs(Int(raw[y * image.bytesPerRow + x]) - Int(out[y * rgba.bytesPerRow + x * 4])))
                                }
                            }
                            grayNote = " grayToRGBAmaxDiff=\(maxDiff)"
                        }
                    }
                }
                let med = { (v: [Double]) in String(format: "%.1f", v.sorted()[v.count / 2]) }
                print("EXPERIMENT fixture=\(fixture.name) bound=\(bound) shipped=\(med(shipped)) direct=\(med(direct)) coreImage=\(med(core))" + grayNote)
            }
        }
    }
}


// MARK: - VideoToolbox Motion-JPEG probe

@available(iOS 17.0, *)
enum VTProbe {
    static func fourCC(_ value: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
    }

    /// Decodes one JPEG as a single Motion-JPEG frame. Returns the image buffer, status and milliseconds.
    static func decode(_ data: Data, width: Int, height: Int, requireHardware: Bool,
                       reduced: (Int, Int)?) -> (CVImageBuffer?, OSStatus, Double, Bool?, OSStatus) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(width),
                                       height: Int32(height), extensions: nil, formatDescriptionOut: &format)
        let spec: [CFString: Any] = requireHardware
            ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
            : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format!,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { return (nil, created, 0, nil, noErr) }
        defer { VTDecompressionSessionInvalidate(session) }
        var reducedStatus: OSStatus = noErr
        if let reduced {
            reducedStatus = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_ReducedResolutionDecode,
                value: [kVTDecompressionResolutionKey_Width: reduced.0, kVTDecompressionResolutionKey_Height: reduced.1] as CFDictionary)
        }
        var usingHardware: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: &usingHardware)
        var output: CVImageBuffer?
        var decodeStatus: OSStatus = noErr
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        data.withUnsafeBytes { bytes in
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                blockLength: bytes.count, blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            var sample: CMSampleBuffer?
            var size = bytes.count
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample)
            let submitted = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                decodeStatus = status
                output = image
            }
            if submitted != noErr { decodeStatus = submitted }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        return (output, decodeStatus, ms, (usingHardware as? Bool), reducedStatus)
    }

    static func run(fixtures: [Fixture], device: MTLDevice) {
        print("VT hardwareDecodeSupported(JPEG)=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_JPEG))")
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        for fixture in fixtures where fixture.codec == .jpeg {
            for (label, reduced) in [("full", nil), ("quarter", (fixture.width / 4, fixture.height / 4))] as [(String, (Int, Int)?)] {
                for hardware in [true, false] {
                    var times: [Double] = []
                    var report = ""
                    for iteration in 0..<5 {
                        autoreleasepool {
                            let (image, status, ms, usingHW, reducedStatus) = decode(fixture.data, width: fixture.width,
                                height: fixture.height, requireHardware: hardware, reduced: reduced)
                            guard let image, status == noErr else {
                                report = "status=\(status)"
                                return
                            }
                            times.append(ms)
                            guard iteration == 0 else { return }
                            let pixelFormat = CVPixelBufferGetPixelFormatType(image)
                            let planes = CVPixelBufferGetPlaneCount(image)
                            let ioSurface = CVPixelBufferGetIOSurface(image) != nil
                            // Zero-copy Metal view of the luma (or only) plane.
                            var metal: CVMetalTexture?
                            let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                            let w = planes > 0 ? CVPixelBufferGetWidthOfPlane(image, 0) : CVPixelBufferGetWidth(image)
                            let h = planes > 0 ? CVPixelBufferGetHeightOfPlane(image, 0) : CVPixelBufferGetHeight(image)
                            let wrapStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache!, image, nil,
                                planes > 0 ? .r8Unorm : .bgra8Unorm, w, h, 0, &metal)
                            let wrapMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t) / 1e6
                            // Luma sanity check against ImageIO for the gray page.
                            var lumaDiff = "n/a"
                            if fixture.isGray, planes > 0, reduced == nil {
                                let source = CGImageSourceCreateWithData(fixture.data as CFData, nil)!
                                let reference = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                                let refData = reference.dataProvider!.data!
                                let ref = CFDataGetBytePtr(refData)!
                                CVPixelBufferLockBaseAddress(image, .readOnly)
                                let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
                                let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                                var maxDiff = 0
                                for y in stride(from: 0, to: min(h, reference.height), by: 5) {
                                    for x in stride(from: 0, to: min(w, reference.width), by: 5) {
                                        maxDiff = max(maxDiff, abs(Int(luma[y * lumaRow + x]) - Int(ref[y * reference.bytesPerRow + x])))
                                    }
                                }
                                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                                lumaDiff = "\(maxDiff)"
                            }
                            report = "out=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) format=\(fourCC(pixelFormat)) " +
                                "planes=\(planes) ioSurface=\(ioSurface) usingHW=\(usingHW.map { "\($0)" } ?? "unknown") " +
                                "reducedProp=\(reducedStatus) metalWrap=\(wrapStatus == kCVReturnSuccess ? String(format: "%.2fms", wrapMs) : "failed(\(wrapStatus))") " +
                                "lumaMaxDiffVsImageIO=\(lumaDiff)"
                        }
                    }
                    let median = times.isEmpty ? "-" : String(format: "%.1f", times.sorted()[times.count / 2])
                    print("VT fixture=\(fixture.name) request=\(label) hardware=\(hardware ? "required" : "disabled") decodeMs=\(median) \(report)")
                }
            }
        }
    }
}


// MARK: - makeTexture memory probe

/// Zoom-tile crops for TASKS item 5: the shipped TurboJPEG region decode against the
/// full ImageIO decode it would replace — uncached, and with the full decode already cached.
enum CropProbe {
    static func run(fixtures: URL) throws {
        let screen = CGSize(width: 2064, height: 2752)
        var files = ["page-5000x10000.jpeg", "manga-2160x3072-gray.jpeg"].map(fixtures.appendingPathComponent)
        let real = fixtures.appendingPathComponent("real")
        if let page = (try? FileManager.default.contentsOfDirectory(at: real, includingPropertiesForKeys: nil))?
            .filter({ $0.pathExtension == "jpg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            files.append(page)
        }
        for url in files {
            guard let data = try? Data(contentsOf: url), let probe = ImageSource(data: data) else { continue }
            let size = probe.imageSize
            print("CROP page=\(url.lastPathComponent) size=\(Int(size.width))x\(Int(size.height)) regionDecodable=\(probe.isRegionDecodable)")
            let formats: [PixelBuffer.PixelFormat] = probe.colorModel == .grayscale ? [.rgba8, .gray8] : [.rgba8]
            for fraction in [0.5, 0.25] {
                let crop = CGRect(x: size.width * (1 - fraction) / 2, y: size.height * (1 - fraction) / 2,
                                  width: size.width * fraction, height: size.height * fraction)
                for format in formats {
                    var region: [Double] = [], uncached: [Double] = [], cached: [Double] = []
                    var output = ""
                    for iteration in 0..<10 {
                        try autoreleasepool {
                            let clock = { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
                            // Shipped crop path on a fresh source: TurboJPEG region decode.
                            let regionSource = ImageSource(data: data)!
                            var start = clock()
                            let tile = try regionSource.decode(targetSize: screen, cropRect: crop, pixelFormat: format)
                            let r = clock() - start
                            output = "\(tile.width)x\(tile.height)"
                            // The fallback used for non-region sources: full ImageIO decode,
                            // CGImage crop, one render to the target. Fresh source = cold cache.
                            let fresh = ImageSource(data: data)!
                            let clamped = try SoftwareScaler.clampedCrop(crop, in: fresh.imageSize)
                            let outSize = try SoftwareScaler.outputSize(for: clamped.size, fitting: screen)
                            start = clock()
                            guard let full = fresh.decodeFullCGImage(), let croppedImage = full.cropping(to: clamped) else {
                                throw ImageDecoderError.decodeFailed("Full decode failed")
                            }
                            _ = try fresh.render(croppedImage, size: outSize, pixelFormat: format)
                            let u = clock() - start
                            // Same source again: the full decode is now cached.
                            start = clock()
                            guard let hot = fresh.decodeFullCGImage(), let cropped2 = hot.cropping(to: clamped) else {
                                throw ImageDecoderError.decodeFailed("Cached decode failed")
                            }
                            _ = try fresh.render(cropped2, size: outSize, pixelFormat: format)
                            let c = clock() - start
                            if iteration > 1 { region.append(r); uncached.append(u); cached.append(c) }
                        }
                    }
                    let med = { (v: [Double]) in String(format: "%.2f", v.sorted()[v.count / 2]) }
                    print("CROP   fraction=\(fraction) \(format) output=\(output) region=\(med(region))ms " +
                          "fullUncached=\(med(uncached))ms fullCached=\(med(cached))ms")
                }
            }
        }
    }
}

enum MemoryProbe {
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    final class Peak: @unchecked Sendable {
        let lock = NSLock(); var value: Int64 = 0
        func sample() { let f = MemoryProbe.footprint(); lock.lock(); value = max(value, f); lock.unlock() }
    }

    static func run(fixtures: [Fixture], bench: Bench) throws {
        let label = CommandLine.arguments.first { $0.hasPrefix("--label=") }.map { String($0.dropFirst(8)) } ?? "?"
        for fixture in fixtures {
            for bound in [2048, 1024] {
                for format in fixture.isGray ? [PixelBuffer.PixelFormat.rgba8, .gray8] : [.rgba8] {
                    var times: [Bool: [Double]] = [true: [], false: []], peaks: [Bool: [Int64]] = [true: [], false: []]
                    // Alternate old (copy upload) and new (shared storage) call by call: A, B, A, B...
                    for iteration in 0..<16 {
                        let copyUpload = iteration % 2 == 0
                        ImageSource.benchmarkCopyUpload = copyUpload  // patched in by setup-ios.sh
                        try autoreleasepool {
                            let baseline = footprint()
                            let peak = Peak(); peak.value = baseline
                            let queue = DispatchQueue(label: "memory.sampler", qos: .userInteractive)
                            let timer = DispatchSource.makeTimerSource(queue: queue)
                            timer.schedule(deadline: .now(), repeating: .milliseconds(1))
                            timer.setEventHandler { peak.sample() }
                            timer.resume()
                            let (texture, stages) = try bench.textureAPI(fixture, CGSize(width: bound, height: bound), format)
                            peak.sample()
                            timer.cancel(); queue.sync {}
                            _ = texture
                            if iteration >= 2 {   // the first pair warms caches
                                times[copyUpload]!.append(stages.decode)
                                peaks[copyUpload]!.append(peak.value - baseline)
                            }
                        }
                    }
                    let med = { (v: [Double]) in v.sorted()[v.count / 2] }
                    let medP = { (v: [Int64]) in Double(v.sorted()[v.count / 2]) / 1_048_576 }
                    print(String(format: "AB fixture=%@ bound=%d format=%@ copyMs=%.1f sharedMs=%.1f copyPeakMB=%.1f sharedPeakMB=%.1f",
                                 fixture.name, bound, "\(format)", med(times[true]!), med(times[false]!),
                                 medP(peaks[true]!), medP(peaks[false]!)))
                }
            }
        }
    }
}


// MARK: - Real comic pages

enum RealPages {
    static func run(directory: URL, bench: Bench) throws {
        let screens: [(String, CGSize)] = [("iPhoneSE", CGSize(width: 750, height: 1334)),
                                           ("iPhoneProMax", CGSize(width: 1320, height: 2868)),
                                           ("iPad13", CGSize(width: 2064, height: 2752))]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let data = try Data(contentsOf: url)
            let source = ImageSource(data: data)!
            print("REAL page=\(url.lastPathComponent) size=\(Int(source.imageSize.width))x\(Int(source.imageSize.height)) model=\(source.colorModel.map { "\($0)" } ?? "nil")")
            let fixture = Fixture(name: url.lastPathComponent, codec: .jpeg, isGray: source.colorModel == .grayscale,
                                  width: Int(source.imageSize.width), height: Int(source.imageSize.height), data: data)
            for (name, screen) in screens {
                for format in fixture.isGray ? [PixelBuffer.PixelFormat.gray8, .rgba8] : [.rgba8] {
                    var decode: [Double] = [], texture: [Double] = []
                    var output = ""
                    for iteration in 0..<12 {
                        try autoreleasepool {
                            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                            let buffer = try ImageSource(data: data)!.decode(targetSize: screen, pixelFormat: format)
                            let d = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
                            let (result, stages) = try bench.textureAPI(fixture, screen, format)
                            precondition(result.width == buffer.width && result.height == buffer.height)
                            output = "\(buffer.width)x\(buffer.height)"
                            if iteration > 1 { decode.append(d); texture.append(stages.decode) }
                        }
                    }
                    let med = { (v: [Double]) in String(format: "%.2f", v.sorted()[v.count / 2]) }
                    print("REAL   \(name) \(format) output=\(output) decode=\(med(decode))ms makeTexture=\(med(texture))ms")
                }
            }
        }
    }
}

// MARK: - App entry point

/// Runs the benchmark off the main thread on launch, then exits.
class ViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setvbuf(stdout, nil, _IOLBF, 0)
        Thread.detachNewThread {
            do {
                let bench = Bench(outputDirectory: nil)
                let info = ProcessInfo.processInfo
                var system = utsname()
                uname(&system)
                let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                print("ENV device=\(bench.device.name) model=\(model) os=\(info.operatingSystemVersionString) " +
                      "cores=\(info.activeProcessorCount) memory=\(info.physicalMemory) thermal=\(info.thermalState.rawValue) " +
                      "jxl=\(JxlDecoderVersion()) iterations=\(bench.iterations)")
                let fixtures = Bundle.main.resourceURL!.appendingPathComponent("ProbeFixtures")
                if CommandLine.arguments.contains("--real") {
                    try RealPages.run(directory: fixtures.appendingPathComponent("real"), bench: bench)
                    print("BENCH-DONE")
                    exit(0)
                }
                if CommandLine.arguments.contains("--crop") {
                    try CropProbe.run(fixtures: fixtures)
                    print("BENCH-DONE")
                    exit(0)
                }
                if CommandLine.arguments.contains("--memory") {
                    try MemoryProbe.run(fixtures: try FixtureFactory.all(directory: fixtures), bench: bench)
                    print("BENCH-DONE")
                    exit(0)
                }
                if CommandLine.arguments.contains("--vt") {
                    if #available(iOS 17.0, *) {
                        VTProbe.run(fixtures: try FixtureFactory.all(directory: fixtures), device: bench.device)
                    }
                    print("BENCH-DONE")
                    exit(0)
                }
                if CommandLine.arguments.contains("--experiments") {
                    try Experiments.run(fixtures: try FixtureFactory.all(directory: fixtures), device: bench.device)
                    print("BENCH-DONE")
                    exit(0)
                }
                if CommandLine.arguments.contains("--diag") {
                    try Diagnostics.run(fixtures: try FixtureFactory.all(directory: fixtures), device: bench.device)
                    print("BENCH-DONE")
                    exit(0)
                }
                // Optional launch argument "--only=<substring>" limits the fixtures run.
                let only = CommandLine.arguments.first { $0.hasPrefix("--only=") }.map { String($0.dropFirst(7)) }
                let selected = try FixtureFactory.all(directory: fixtures).filter { only == nil || $0.name.contains(only!) }
                try bench.run(fixtures: selected, targets: [2048, 1024])
                print("ENV-END thermal=\(info.thermalState.rawValue)")
            } catch {
                print("BENCH-ERROR \(error)")
            }
            print("BENCH-DONE")
            exit(0)
        }
    }
}
