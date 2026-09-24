//
//  JXLDecoder.swift
//  ImageIOKit
//
//  libjxl callback decoding with an optional DC-only thumbnail pass.
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
    func decode() throws -> PixelBuffer { try decode(downsampleFactor: 1) }

    /// Returns DC-resolution pixels when sufficient for the requested bounds.
    /// Modular images complete a full decode but retain only subsampled output.
    func decodeThumbnail(fittingSize: CGSize) throws -> PixelBuffer {
        let size = imageSize
        guard size.width > 0, size.height > 0 else { throw ImageDecoderError.invalidData }
        let output = try SoftwareScaler.outputSize(for: CGSize(width: size.width, height: size.height), fitting: fittingSize)
        let dcWidth = (size.width + 7) / 8, dcHeight = (size.height + 7) / 8
        let factor = CGFloat(dcWidth) >= output.width && CGFloat(dcHeight) >= output.height ? 8 : 1
        return try decode(downsampleFactor: factor)
    }

    private func decode(downsampleFactor factor: Int) throws -> PixelBuffer {
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
            if factor > 1 { events |= JXL_DEC_FRAME_PROGRESSION.rawValue }
            guard JxlDecoderSetParallelRunner(decoder, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS,
                  JxlDecoderSubscribeEvents(decoder, Int32(events)) == JXL_DEC_SUCCESS,
                  JxlDecoderSetProgressiveDetail(decoder, kDC) == JXL_DEC_SUCCESS,
                  JxlDecoderSetInput(decoder, base.assumingMemoryBound(to: UInt8.self), bytes.count) == JXL_DEC_SUCCESS else {
                throw ImageDecoderError.decodeFailed("Failed to configure JXL decoder")
            }
            JxlDecoderCloseInput(decoder)
            var width = 0, height = 0
            var space = PixelBuffer.defaultColorSpace(for: .rgba8)
            var format = JxlPixelFormat(num_channels: 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)

            while true {
                let status = JxlDecoderProcessInput(decoder)
                switch status {
                case JXL_DEC_BASIC_INFO:
                    var info = JxlBasicInfo()
                    guard JxlDecoderGetBasicInfo(decoder, &info) == JXL_DEC_SUCCESS,
                          info.xsize > 0, info.ysize > 0 else { throw ImageDecoderError.invalidData }
                    width = (Int(info.xsize) + factor - 1) / factor
                    height = (Int(info.ysize) + factor - 1) / factor
                    context.pointee.premultiply = info.alpha_bits > 0 && info.alpha_premultiplied == 0

                case JXL_DEC_COLOR_ENCODING:
                    var count = 0
                    if JxlDecoderGetICCProfileSize(decoder, JXL_COLOR_PROFILE_TARGET_DATA, &count) == JXL_DEC_SUCCESS, count > 0 {
                        var profile = Data(count: count)
                        let result = profile.withUnsafeMutableBytes {
                            JxlDecoderGetColorAsICCProfile(decoder, JXL_COLOR_PROFILE_TARGET_DATA,
                                $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count)
                        }
                        if result == JXL_DEC_SUCCESS, let decodedSpace = CGColorSpace(iccData: profile as CFData),
                           decodedSpace.model == .rgb { space = decodedSpace }
                    }

                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    guard width > 0, height > 0 else { throw ImageDecoderError.invalidData }
                    context.pointee.pixelBuffer = PixelBuffer(width: width, height: height, pixelFormat: .rgba8, colorSpace: space)
                    let result = JxlDecoderSetImageOutCallback(decoder, &format, { opaque, x, y, count, pixels in
                        guard let opaque, let pixels else { return }
                        let context = opaque.assumingMemoryBound(to: CallbackContext.self).pointee
                        guard let buffer = context.pixelBuffer, y % context.downsampleFactor == 0 else { return }
                        let factor = context.downsampleFactor
                        let src = pixels.assumingMemoryBound(to: UInt8.self)
                        let dst = buffer.data.assumingMemoryBound(to: UInt8.self)
                        if factor == 1 && !context.premultiply {
                            memcpy(dst + y * buffer.bytesPerRow + x * 4, src, count * 4)
                            return
                        }
                        let remainder = x % factor
                        var i = remainder == 0 ? 0 : factor - remainder
                        while i < count {
                            let s = i * 4
                            let d = (y / factor) * buffer.bytesPerRow + ((x + i) / factor) * 4
                            let alpha = Int(src[s + 3])
                            for channel in 0..<3 {
                                dst[d + channel] = context.premultiply
                                    ? UInt8((Int(src[s + channel]) * alpha + 127) / 255) : src[s + channel]
                            }
                            dst[d + 3] = src[s + 3]
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
    var premultiply = false
    var pixelBuffer: PixelBuffer?
}
