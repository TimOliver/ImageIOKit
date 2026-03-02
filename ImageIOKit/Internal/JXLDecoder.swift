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
}

// MARK: - Callback Context

private struct CallbackContext {
    var buffer: UnsafeMutableRawPointer?
    var bytesPerRow: Int = 0
    var pixelBuffer: PixelBuffer?
}
