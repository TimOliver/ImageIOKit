//
//  JXLDecoder.swift
//  ImageIOKit
//
//  libjxl callback decoding with DC-only and filtered thumbnail paths.
//

import Foundation
import CoreGraphics
import jxl

struct JXLDecoder {
    private let imageData: Data

    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        self.imageData = data
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    var imageSize: (width: Int, height: Int) {
        imageData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let decoder = JxlDecoderCreate(nil) else { return (0, 0) }
            defer { JxlDecoderDestroy(decoder) }
            guard JxlDecoderSubscribeEvents(decoder, Int32(JXL_DEC_BASIC_INFO.rawValue)) == JXL_DEC_SUCCESS,
                  JxlDecoderSetInput(decoder, base.assumingMemoryBound(to: UInt8.self), bytes.count) == JXL_DEC_SUCCESS else {
                return (0, 0)
            }
            JxlDecoderCloseInput(decoder)
            guard JxlDecoderProcessInput(decoder) == JXL_DEC_BASIC_INFO else { return (0, 0) }
            var info = JxlBasicInfo()
            guard JxlDecoderGetBasicInfo(decoder, &info) == JXL_DEC_SUCCESS else { return (0, 0) }
            return (Int(info.xsize), Int(info.ysize))
        }
    }

    /// Returns the first displayed frame, with orientation applied and premultiplied alpha.
    /// Grayscale sources decode to `gray8` or `grayAlpha8` when `prefersGrayscale` is set;
    /// otherwise all output is `rgba8`.
    func decode(prefersGrayscale: Bool = false) throws -> PixelBuffer {
        try decode(downsampleFactor: 1, prefersGrayscale: prefersGrayscale)
    }

    /// Returns DC-resolution pixels when sufficient for the requested bounds.
    /// Larger thumbnails average 2x2 or 4x4 blocks during decode, avoiding a full-size output bitmap.
    /// Codec working storage can still depend on the source dimensions.
    func decodeThumbnail(fittingSize: CGSize, prefersGrayscale: Bool = false) throws -> PixelBuffer {
        let size = imageSize
        guard size.width > 0, size.height > 0 else { throw ImageDecoderError.invalidData }
        let output = try SoftwareScaler.outputSize(for: CGSize(width: size.width, height: size.height), fitting: fittingSize)
        let dcWidth = (size.width + 7) / 8, dcHeight = (size.height + 7) / 8
        let outputWidth = Int(output.width), outputHeight = Int(output.height)
        // Explicit types: older compilers time out type-checking this as one expression.
        let covers: (Int) -> Bool = { (factor: Int) -> Bool in
            let width: Int = (size.width + factor - 1) / factor
            let height: Int = (size.height + factor - 1) / factor
            return width >= outputWidth && height >= outputHeight
        }
        let factor: Int
        if dcWidth >= outputWidth && dcHeight >= outputHeight {
            factor = 8
        } else {
            factor = [4, 2].first(where: covers) ?? 1
        }
        return try decode(downsampleFactor: factor, prefersGrayscale: prefersGrayscale)
    }

    private func decode(downsampleFactor factor: Int, prefersGrayscale: Bool) throws -> PixelBuffer {
        // The decoder is destroyed before this input borrow ends. The callback context
        // has separately allocated, stable storage for all ProcessInput/FlushImage calls.
        try imageData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ImageDecoderError.invalidData }
            guard let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads()) else {
                throw ImageDecoderError.decodeFailed("Failed to create JXL parallel runner")
            }
            defer { JxlThreadParallelRunnerDestroy(runner) }
            let context = UnsafeMutablePointer<CallbackContext>.allocate(capacity: 1)
            context.initialize(to: CallbackContext(downsampleFactor: factor))
            defer { context.deinitialize(count: 1); context.deallocate() }
            guard let decoder = JxlDecoderCreate(nil) else {
                throw ImageDecoderError.decodeFailed("Failed to create JXL decoder")
            }
            defer { JxlDecoderDestroy(decoder) }

            var events = JXL_DEC_BASIC_INFO.rawValue | JXL_DEC_COLOR_ENCODING.rawValue | JXL_DEC_FULL_IMAGE.rawValue
            if factor == 8 { events |= JXL_DEC_FRAME_PROGRESSION.rawValue }
            guard JxlDecoderSetParallelRunner(decoder, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS,
                  JxlDecoderSubscribeEvents(decoder, Int32(events)) == JXL_DEC_SUCCESS,
                  JxlDecoderSetProgressiveDetail(decoder, kDC) == JXL_DEC_SUCCESS,
                  JxlDecoderSetInput(decoder, base.assumingMemoryBound(to: UInt8.self), bytes.count) == JXL_DEC_SUCCESS else {
                throw ImageDecoderError.decodeFailed("Failed to configure JXL decoder")
            }
            JxlDecoderCloseInput(decoder)
            var width = 0, height = 0
            var sourceWidth = 0, sourceHeight = 0
            var pixelFormat = PixelBuffer.PixelFormat.rgba8
            var space = PixelBuffer.defaultColorSpace(for: .rgba8)
            var format = JxlPixelFormat(num_channels: 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)

            while true {
                let status = JxlDecoderProcessInput(decoder)
                switch status {
                case JXL_DEC_BASIC_INFO:
                    var info = JxlBasicInfo()
                    guard JxlDecoderGetBasicInfo(decoder, &info) == JXL_DEC_SUCCESS,
                          info.xsize > 0, info.ysize > 0 else { throw ImageDecoderError.invalidData }
                    sourceWidth = Int(info.xsize); sourceHeight = Int(info.ysize)
                    width = (sourceWidth + factor - 1) / factor
                    height = (Int(info.ysize) + factor - 1) / factor
                    context.pointee.premultiply = info.alpha_bits > 0 && info.alpha_premultiplied == 0
                    // Keeping grayscale sources in one or two channels skips libjxl's RGB
                    // expansion and quarters or halves the output and callback traffic.
                    if prefersGrayscale && info.num_color_channels == 1 {
                        pixelFormat = info.alpha_bits > 0 ? .grayAlpha8 : .gray8
                        space = PixelBuffer.defaultColorSpace(for: pixelFormat)
                    }
                    format.num_channels = UInt32(pixelFormat.bytesPerPixel)
                    context.pointee.channels = pixelFormat.bytesPerPixel

                case JXL_DEC_COLOR_ENCODING:
                    // libjxl describes sRGB output with a generated ICC profile that CoreGraphics
                    // does not equate with kCGColorSpaceSRGB, forcing color matching on every draw.
                    // Keep the named space for nominal sRGB RGBA output (including gray expanded to RGB).
                    var encoding = JxlColorEncoding()
                    if pixelFormat == .rgba8,
                       JxlDecoderGetColorAsEncodedProfile(decoder, JXL_COLOR_PROFILE_TARGET_DATA, &encoding) == JXL_DEC_SUCCESS,
                       encoding.color_space == JXL_COLOR_SPACE_GRAY
                        || (encoding.color_space == JXL_COLOR_SPACE_RGB && encoding.primaries == JXL_PRIMARIES_SRGB),
                       encoding.white_point == JXL_WHITE_POINT_D65,
                       encoding.transfer_function == JXL_TRANSFER_FUNCTION_SRGB {
                        break
                    }
                    var count = 0
                    if JxlDecoderGetICCProfileSize(decoder, JXL_COLOR_PROFILE_TARGET_DATA, &count) == JXL_DEC_SUCCESS, count > 0 {
                        var profile = Data(count: count)
                        let result = profile.withUnsafeMutableBytes {
                            JxlDecoderGetColorAsICCProfile(decoder, JXL_COLOR_PROFILE_TARGET_DATA,
                                $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count)
                        }
                        let model: CGColorSpaceModel = pixelFormat == .rgba8 ? .rgb : .monochrome
                        if result == JXL_DEC_SUCCESS, let decodedSpace = CGColorSpace(iccData: profile as CFData),
                           decodedSpace.model == model { space = decodedSpace }
                    }

                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    guard width > 0, height > 0 else { throw ImageDecoderError.invalidData }
                    if factor == 2 || factor == 4 {
                        context.pointee.downsampler = JXLBoxDownsampler(width: sourceWidth, height: sourceHeight,
                            factor: factor, pixelFormat: pixelFormat, premultiply: context.pointee.premultiply,
                            colorSpace: space)
                    } else {
                        context.pointee.pixelBuffer = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat, colorSpace: space)
                    }
                    let result = JxlDecoderSetImageOutCallback(decoder, &format, { opaque, x, y, count, pixels in
                        guard let opaque, let pixels else { return }
                        let context = opaque.assumingMemoryBound(to: CallbackContext.self).pointee
                        if let downsampler = context.downsampler {
                            downsampler.consume(x: x, y: y, count: count, pixels: pixels)
                            return
                        }
                        guard let buffer = context.pixelBuffer, y % context.downsampleFactor == 0 else { return }
                        let factor = context.downsampleFactor
                        let channels = context.channels
                        let src = pixels.assumingMemoryBound(to: UInt8.self)
                        let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
                        if factor == 1 && !context.premultiply {
                            memcpy(dst + y * buffer.bytesPerRow + x * channels, src, count * channels)
                            return
                        }
                        // Premultiplication only applies to two- and four-channel output,
                        // where alpha is always the last component.
                        let alphaIndex = channels - 1
                        let remainder = x % factor
                        var i = remainder == 0 ? 0 : factor - remainder
                        while i < count {
                            let s = i * channels
                            let d = (y / factor) * buffer.bytesPerRow + ((x + i) / factor) * channels
                            let alpha = Int(src[s + alphaIndex])
                            for channel in 0..<alphaIndex {
                                dst[d + channel] = context.premultiply
                                    ? UInt8((Int(src[s + channel]) * alpha + 127) / 255) : src[s + channel]
                            }
                            dst[d + alphaIndex] = src[s + alphaIndex]
                            i += factor
                        }
                    }, context)
                    guard result == JXL_DEC_SUCCESS else {
                        throw ImageDecoderError.decodeFailed("Failed to set JXL output callback")
                    }

                case JXL_DEC_FRAME_PROGRESSION:
                    guard JxlDecoderFlushImage(decoder) == JXL_DEC_SUCCESS,
                          let buffer = context.pointee.pixelBuffer else {
                        throw ImageDecoderError.decodeFailed("Failed to flush JXL DC pixels")
                    }
                    return buffer

                case JXL_DEC_FULL_IMAGE:
                    if let downsampler = context.pointee.downsampler { return downsampler.finish() }
                    guard let buffer = context.pointee.pixelBuffer else { throw ImageDecoderError.invalidData }
                    return buffer

                default:
                    throw ImageDecoderError.decodeFailed("JXL decode ended without a frame: \(status.rawValue)")
                }
            }
        }
    }
}

private struct CallbackContext {
    var downsampleFactor: Int
    var channels = 4
    var premultiply = false
    var pixelBuffer: PixelBuffer?
    var downsampler: JXLBoxDownsampler?
}


/// Integer box filtering for final-pass callbacks, which visit each source pixel exactly once.
/// Callbacks can arrive in arbitrary horizontal fragments, in parallel and out of row order.
/// One lock per destination row protects overlapping contributions without serializing the image.
/// Progressive flushes must not feed this accumulator: they may revisit pixels.
final class JXLBoxDownsampler {
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let width: Int
    private let height: Int
    private let factor: Int
    private let pixelFormat: PixelBuffer.PixelFormat
    private let channels: Int
    private let premultiply: Bool
    private let colorSpace: CGColorSpace
    private let sums: UnsafeMutablePointer<UInt16>
    private let locks: [NSLock]

    /// `pixelFormat` describes both the callback pixels and the output; `rgb8` is unsupported.
    init(width: Int, height: Int, factor: Int, pixelFormat: PixelBuffer.PixelFormat = .rgba8,
         premultiply: Bool, colorSpace: CGColorSpace) {
        precondition(width > 0 && height > 0 && (factor == 2 || factor == 4) && pixelFormat != .rgb8)
        sourceWidth = width; sourceHeight = height
        self.width = (width + factor - 1) / factor
        self.height = (height + factor - 1) / factor
        self.factor = factor; self.pixelFormat = pixelFormat; channels = pixelFormat.bytesPerPixel
        // Only alpha-bearing layouts can be premultiplied.
        self.premultiply = premultiply && pixelFormat.hasAlpha; self.colorSpace = colorSpace
        let count = self.width * self.height * channels
        sums = .allocate(capacity: count)
        sums.initialize(repeating: 0, count: count)
        locks = (0..<self.height).map { _ in NSLock() }
    }

    deinit { sums.deallocate() }

    func consume(x: Int, y: Int, count: Int, pixels: UnsafeRawPointer) {
        let row = y / factor
        let source = pixels.assumingMemoryBound(to: UInt8.self)
        locks[row].lock()
        defer { locks[row].unlock() }
        var i = 0
        while i < count {
            let column = (x + i) / factor
            let end = min(count, (column + 1) * factor - x)
            // Gray layouts accumulate into r (and a); RGBA uses all four.
            var r = 0, g = 0, b = 0, a = 0
            while i < end {
                let offset = i * channels
                switch channels {
                case 4:
                    let alpha = Int(source[offset + 3])
                    if premultiply {
                        r += (Int(source[offset]) * alpha + 127) / 255
                        g += (Int(source[offset + 1]) * alpha + 127) / 255
                        b += (Int(source[offset + 2]) * alpha + 127) / 255
                    } else {
                        r += Int(source[offset]); g += Int(source[offset + 1]); b += Int(source[offset + 2])
                    }
                    a += alpha
                case 2:
                    let alpha = Int(source[offset + 1])
                    r += premultiply ? (Int(source[offset]) * alpha + 127) / 255 : Int(source[offset])
                    a += alpha
                default:
                    r += Int(source[offset])
                }
                i += 1
            }
            // At most 4x4 contributions of 255: all sums fit in UInt16.
            let destination = (row * width + column) * channels
            switch channels {
            case 4:
                sums[destination] += UInt16(r)
                sums[destination + 1] += UInt16(g)
                sums[destination + 2] += UInt16(b)
                sums[destination + 3] += UInt16(a)
            case 2:
                sums[destination] += UInt16(r)
                sums[destination + 1] += UInt16(a)
            default:
                sums[destination] += UInt16(r)
            }
        }
    }

    /// Called only after the decoder has joined all callbacks.
    func finish() -> PixelBuffer {
        let output = PixelBuffer(width: width, height: height, pixelFormat: pixelFormat, colorSpace: colorSpace)
        let destination = output.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let samples = min(factor, sourceWidth - x * factor) * min(factor, sourceHeight - y * factor)
                let offset = (y * width + x) * channels
                for channel in 0..<channels {
                    destination[offset + channel] = UInt8((Int(sums[offset + channel]) + samples / 2) / samples)
                }
            }
        }
        return output
    }
}
