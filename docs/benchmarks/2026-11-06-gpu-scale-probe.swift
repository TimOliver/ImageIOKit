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
import CoreGraphics
import ImageIO
import Metal
import MetalPerformanceShaders
import UniformTypeIdentifiers
import jxl
@testable import ImageIOKit

setvbuf(stdout, nil, _IOLBF, 0)

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
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    // Kernels are created once, as a reader would keep them for its lifetime.
    lazy var lanczos = MPSImageLanczosScale(device: device)
    lazy var bilinear = MPSImageBilinearScale(device: device)
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
        if fixture.codec == .jpeg {
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
        let factor = [8, 4, 2].first {
            (fixture.width + $0 - 1) / $0 >= Int(size.width) && (fixture.height + $0 - 1) / $0 >= Int(size.height)
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
                      "output=\(Int(size.width))x\(Int(size.height)) native=\(nativeSize)")
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

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: GPUScaleBench <fixture-dir> [output-dir]")
    exit(2)
}
let bench = Bench(outputDirectory: arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil)
let info = ProcessInfo.processInfo
print("ENV device=\(bench.device.name) os=\(info.operatingSystemVersionString) cores=\(info.activeProcessorCount) " +
      "thermal=\(info.thermalState.rawValue) jxl=\(JxlDecoderVersion()) iterations=\(bench.iterations)")
let fixtures = try FixtureFactory.all(directory: URL(fileURLWithPath: arguments[1]))
try bench.run(fixtures: fixtures, targets: [2048, 1024])
print("\nENV-END thermal=\(info.thermalState.rawValue)")
