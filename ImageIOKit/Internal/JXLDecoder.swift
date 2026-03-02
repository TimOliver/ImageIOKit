//
//  JXLDecoder.swift
//  ImageIOKit
//
//  Memory-efficient JXL decode via libjxl's scanline callback API.
//  Uses JxlDecoderSetImageOutCallback to write decoded scanlines
//  directly into the PixelBuffer, avoiding a separate output buffer
//  allocation.
//

import Foundation
import jxl

struct JXLDecoder {

    private let imageData: Data

    /// Creates a decoder from in-memory JXL data.
    /// - Parameter data: The compressed JXL data.
    /// - Returns: `nil` if the data is empty.
    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        self.imageData = data
    }

    /// Creates a decoder from a JXL file on disk.
    /// - Parameter url: A local file URL to a JXL file.
    /// - Returns: `nil` if the file cannot be read.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    /// The image dimensions read from the JXL header, or `(0, 0)` if
    /// the header cannot be parsed.
    var imageSize: (width: Int, height: Int) {
        guard let dec = JxlDecoderCreate(nil) else { return (0, 0) }
        defer { JxlDecoderDestroy(dec) }

        guard JxlDecoderSubscribeEvents(dec, Int32(JXL_DEC_BASIC_INFO.rawValue)) == JXL_DEC_SUCCESS else {
            return (0, 0)
        }

        let inputResult = imageData.withUnsafeBytes { buf -> JxlDecoderStatus in
            guard let base = buf.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, base.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else { return (0, 0) }
        JxlDecoderCloseInput(dec)

        guard JxlDecoderProcessInput(dec) == JXL_DEC_BASIC_INFO else { return (0, 0) }

        var info = JxlBasicInfo()
        guard JxlDecoderGetBasicInfo(dec, &info) == JXL_DEC_SUCCESS else { return (0, 0) }
        return (Int(info.xsize), Int(info.ysize))
    }

    /// Decodes the full image into a `PixelBuffer` using libjxl's scanline
    /// callback. The callback writes directly into the pixel buffer's
    /// backing memory, avoiding a separate output allocation.
    func decode() throws -> PixelBuffer {
        guard let dec = JxlDecoderCreate(nil) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL decoder")
        }
        defer { JxlDecoderDestroy(dec) }

        // Set up multithreaded parallel runner
        let numThreads = JxlThreadParallelRunnerDefaultNumWorkerThreads()
        guard let runner = JxlThreadParallelRunnerCreate(nil, numThreads) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL parallel runner")
        }
        defer { JxlThreadParallelRunnerDestroy(runner) }

        guard JxlDecoderSetParallelRunner(dec, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("Failed to set parallel runner")
        }

        // Subscribe to informative events. JXL_DEC_NEED_IMAGE_OUT_BUFFER
        // is delivered automatically and must not be in the subscribe mask.
        let events = Int32(JXL_DEC_BASIC_INFO.rawValue | JXL_DEC_FULL_IMAGE.rawValue)
        guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("Failed to subscribe to decoder events")
        }

        // Provide input data
        let inputResult = imageData.withUnsafeBytes { buf -> JxlDecoderStatus in
            guard let base = buf.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, base.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.invalidData
        }
        JxlDecoderCloseInput(dec)

        // Context passed to the C callback via opaque pointer
        var callbackContext = CallbackContext()

        // Pixel format: 4-channel RGBA, UInt8
        var format = JxlPixelFormat(
            num_channels: 4,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        var status = JxlDecoderProcessInput(dec)
        while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
            switch status {
            case JXL_DEC_BASIC_INFO:
                var info = JxlBasicInfo()
                guard JxlDecoderGetBasicInfo(dec, &info) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("Failed to read basic info")
                }
                let width = Int(info.xsize)
                let height = Int(info.ysize)
                guard width > 0, height > 0 else {
                    throw ImageDecoderError.decodeFailed("Invalid image dimensions: \(width)x\(height)")
                }
                let pixelBuffer = PixelBuffer(width: width, height: height, pixelFormat: .rgba8)
                callbackContext.buffer = pixelBuffer.data
                callbackContext.bytesPerRow = pixelBuffer.bytesPerRow
                callbackContext.pixelBuffer = pixelBuffer

            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                guard callbackContext.buffer != nil else {
                    throw ImageDecoderError.decodeFailed("Output buffer not allocated before callback setup")
                }
                let result = withUnsafeMutablePointer(to: &callbackContext) { ctxPtr in
                    JxlDecoderSetImageOutCallback(
                        dec,
                        &format,
                        { opaque, x, y, numPixels, pixels in
                            guard let opaque, let pixels else { return }
                            let ctx = opaque.assumingMemoryBound(to: CallbackContext.self).pointee
                            guard let buffer = ctx.buffer else { return }
                            let destOffset = y * ctx.bytesPerRow + x * 4
                            let dest = buffer.advanced(by: destOffset)
                            dest.copyMemory(from: pixels, byteCount: numPixels * 4)
                        },
                        ctxPtr
                    )
                }
                guard result == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("Failed to set image output callback")
                }

            case JXL_DEC_FULL_IMAGE:
                // Decode complete
                break

            default:
                throw ImageDecoderError.decodeFailed("Unexpected decoder status: \(status.rawValue)")
            }
            status = JxlDecoderProcessInput(dec)
        }

        guard status == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("JXL decode failed with status \(status.rawValue)")
        }
        guard let pixelBuffer = callbackContext.pixelBuffer else {
            throw ImageDecoderError.decodeFailed("No pixel data produced")
        }
        return pixelBuffer
    }

    /// Decodes a thumbnail appropriate for the given bounding box.
    ///
    /// When the requested size is small enough that 1/8th resolution (DC coefficients)
    /// still exceeds it, uses libjxl's progressive API to decode only the DC data —
    /// saving ~98% of decode memory and skipping the AC passes entirely.
    ///
    /// When the requested size is larger than 1/8th resolution, falls back to a full
    /// decode so the caller doesn't have to upscale a blocky DC image.
    ///
    /// - Parameter fittingSize: The bounding box the thumbnail must fit within.
    /// - Returns: A `PixelBuffer` — either at ~1/8th resolution (DC path) or
    ///   full resolution (fallback path).
    func decodeThumbnail(fittingSize: CGSize) throws -> PixelBuffer {
        let size = imageSize
        guard size.width > 0, size.height > 0 else {
            throw ImageDecoderError.invalidData
        }

        // Check whether 1/8th resolution is still large enough for the requested size
        let dcWidth = CGFloat((size.width + 7) / 8)
        let dcHeight = CGFloat((size.height + 7) / 8)
        let dcScale = min(fittingSize.width / dcWidth, fittingSize.height / dcHeight)

        // If DC would need upscaling to fill the bounding box, do a full decode instead
        if dcScale > 1.0 {
            return try decode()
        }

        return try decodeDCOnly()
    }

    // MARK: - DC-Only Decode

    /// Decodes only the DC coefficients (1/8th resolution) by subsampling in the
    /// scanline callback.
    ///
    /// For VarDCT images, libjxl's progressive API fires `JXL_DEC_FRAME_PROGRESSION`
    /// when the DC data is ready. We flush those pixels via the scanline callback
    /// (which picks every 8th pixel), then skip the AC passes entirely.
    ///
    /// For non-VarDCT (modular/lossless) images, `JXL_DEC_FRAME_PROGRESSION` never
    /// fires. The full decode completes normally, but the subsampling callback still
    /// picks every 8th pixel, producing the same 1/8th-resolution output.
    private func decodeDCOnly() throws -> PixelBuffer {
        guard let dec = JxlDecoderCreate(nil) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL decoder")
        }
        defer { JxlDecoderDestroy(dec) }

        // Set up multithreaded parallel runner
        let numThreads = JxlThreadParallelRunnerDefaultNumWorkerThreads()
        guard let runner = JxlThreadParallelRunnerCreate(nil, numThreads) else {
            throw ImageDecoderError.decodeFailed("Failed to create JXL parallel runner")
        }
        defer { JxlThreadParallelRunnerDestroy(runner) }

        guard JxlDecoderSetParallelRunner(dec, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("Failed to set parallel runner")
        }

        // Subscribe to events including frame progression for DC-only decode
        let events = Int32(
            JXL_DEC_BASIC_INFO.rawValue |
            JXL_DEC_FRAME_PROGRESSION.rawValue |
            JXL_DEC_FULL_IMAGE.rawValue
        )
        guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("Failed to subscribe to decoder events")
        }

        // Request DC-level progressive events
        guard JxlDecoderSetProgressiveDetail(dec, kDC) == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("Failed to set progressive detail")
        }

        // Provide input data
        let inputResult = imageData.withUnsafeBytes { buf -> JxlDecoderStatus in
            guard let base = buf.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, base.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.invalidData
        }
        JxlDecoderCloseInput(dec)

        let downsampleFactor = 8
        var callbackContext = CallbackContext()
        callbackContext.downsampleFactor = downsampleFactor

        var format = JxlPixelFormat(
            num_channels: 4,
            data_type: JXL_TYPE_UINT8,
            endianness: JXL_NATIVE_ENDIAN,
            align: 0
        )

        var status = JxlDecoderProcessInput(dec)
        while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
            switch status {
            case JXL_DEC_BASIC_INFO:
                var info = JxlBasicInfo()
                guard JxlDecoderGetBasicInfo(dec, &info) == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("Failed to read basic info")
                }
                let width = Int(info.xsize)
                let height = Int(info.ysize)
                guard width > 0, height > 0 else {
                    throw ImageDecoderError.decodeFailed("Invalid image dimensions: \(width)x\(height)")
                }
                // Allocate 1/8th resolution output buffer
                let dcWidth = (width + downsampleFactor - 1) / downsampleFactor
                let dcHeight = (height + downsampleFactor - 1) / downsampleFactor
                let pixelBuffer = PixelBuffer(width: dcWidth, height: dcHeight, pixelFormat: .rgba8)
                callbackContext.buffer = pixelBuffer.data
                callbackContext.bytesPerRow = pixelBuffer.bytesPerRow
                callbackContext.pixelBuffer = pixelBuffer

            case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                guard callbackContext.buffer != nil else {
                    throw ImageDecoderError.decodeFailed("Output buffer not allocated before callback setup")
                }
                let result = withUnsafeMutablePointer(to: &callbackContext) { ctxPtr in
                    JxlDecoderSetImageOutCallback(
                        dec,
                        &format,
                        { opaque, x, y, numPixels, pixels in
                            guard let opaque, let pixels else { return }
                            let ctx = opaque.assumingMemoryBound(to: CallbackContext.self).pointee
                            guard let buffer = ctx.buffer else { return }
                            let factor = ctx.downsampleFactor

                            // Only process rows at multiples of the downsample factor
                            guard y % factor == 0 else { return }
                            let destY = y / factor

                            let src = pixels.assumingMemoryBound(to: UInt8.self)
                            let dst = buffer.assumingMemoryBound(to: UInt8.self)

                            // Find the first pixel in this run aligned to the factor grid
                            let remainder = x % factor
                            var i = remainder == 0 ? 0 : (factor - remainder)
                            while i < numPixels {
                                let destX = (x + i) / factor
                                let srcOff = i * 4
                                let dstOff = destY * ctx.bytesPerRow + destX * 4
                                dst[dstOff]     = src[srcOff]
                                dst[dstOff + 1] = src[srcOff + 1]
                                dst[dstOff + 2] = src[srcOff + 2]
                                dst[dstOff + 3] = src[srcOff + 3]
                                i += factor
                            }
                        },
                        ctxPtr
                    )
                }
                guard result == JXL_DEC_SUCCESS else {
                    throw ImageDecoderError.decodeFailed("Failed to set image output callback")
                }

            case JXL_DEC_FRAME_PROGRESSION:
                // DC (1/8th resolution) is ready — flush pixels via callback, then skip AC
                _ = JxlDecoderFlushImage(dec)
                _ = JxlDecoderSkipCurrentFrame(dec)

            case JXL_DEC_FULL_IMAGE:
                // Reached for non-progressive images (fallback); subsampling callback
                // already handled the pixels during the normal decode.
                break

            default:
                break
            }
            status = JxlDecoderProcessInput(dec)
        }

        guard status == JXL_DEC_SUCCESS else {
            throw ImageDecoderError.decodeFailed("JXL thumbnail decode failed with status \(status.rawValue)")
        }
        guard let pixelBuffer = callbackContext.pixelBuffer else {
            throw ImageDecoderError.decodeFailed("No pixel data produced")
        }
        return pixelBuffer
    }
}

// MARK: - Callback Context

private struct CallbackContext {
    var buffer: UnsafeMutableRawPointer?
    var bytesPerRow: Int = 0
    var pixelBuffer: PixelBuffer?
    var downsampleFactor: Int = 1
}
