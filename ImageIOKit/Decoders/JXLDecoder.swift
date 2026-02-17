//
//  JXLReconstructor.swift
//  ImageIOKit
//
//  Lossless JPEG reconstruction from JXL files using libjxl.
//  For JXL files that were created by losslessly recompressing a JPEG,
//  this reconstructs the exact original JPEG bitstream.
//

import Foundation
import libjxl

public struct JXLReconstructor {

    private let imageData: Data

    public init?(data: Data) {
        guard !data.isEmpty else { return nil }
        self.imageData = data
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    /// Attempts to reconstruct the original JPEG bitstream from a JXL file
    /// that was created by losslessly recompressing a JPEG. Returns the exact
    /// original JPEG bytes, or `nil` if the JXL was not derived from a JPEG.
    public func reconstructJPEG() -> Data? {
        guard let dec = JxlDecoderCreate(nil) else { return nil }
        defer { JxlDecoderDestroy(dec) }

        let events = Int32(JXL_DEC_JPEG_RECONSTRUCTION.rawValue | JXL_DEC_FULL_IMAGE.rawValue)
        guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else { return nil }

        let inputResult = imageData.withUnsafeBytes { bufferPtr -> JxlDecoderStatus in
            guard let baseAddress = bufferPtr.baseAddress else { return JXL_DEC_ERROR }
            return JxlDecoderSetInput(dec, baseAddress.assumingMemoryBound(to: UInt8.self), imageData.count)
        }
        guard inputResult == JXL_DEC_SUCCESS else { return nil }
        JxlDecoderCloseInput(dec)

        // Start with a buffer roughly the size of the JXL input (JPEG is typically larger)
        var jpegBuffer = [UInt8](repeating: 0, count: max(imageData.count * 2, 65536))
        var totalWritten = 0

        var status = JxlDecoderProcessInput(dec)
        while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
            switch status {
            case JXL_DEC_JPEG_RECONSTRUCTION:
                // JXL contains a reconstructable JPEG — set the output buffer
                let setResult = jpegBuffer.withUnsafeMutableBufferPointer { ptr -> JxlDecoderStatus in
                    JxlDecoderSetJPEGBuffer(dec, ptr.baseAddress!, ptr.count)
                }
                guard setResult == JXL_DEC_SUCCESS else { return nil }

            case JXL_DEC_JPEG_NEED_MORE_OUTPUT:
                // Buffer too small — release, grow, and set remaining space
                let unused = jpegBuffer.withUnsafeMutableBufferPointer { _ in
                    JxlDecoderReleaseJPEGBuffer(dec)
                }
                totalWritten = jpegBuffer.count - unused

                // Double the buffer
                let newSize = jpegBuffer.count * 2
                jpegBuffer.append(contentsOf: [UInt8](repeating: 0, count: jpegBuffer.count))

                let setResult = jpegBuffer.withUnsafeMutableBufferPointer { ptr -> JxlDecoderStatus in
                    JxlDecoderSetJPEGBuffer(dec, ptr.baseAddress! + totalWritten, newSize - totalWritten)
                }
                guard setResult == JXL_DEC_SUCCESS else { return nil }

            case JXL_DEC_FULL_IMAGE:
                // Reconstruction complete
                let unused = jpegBuffer.withUnsafeMutableBufferPointer { _ in
                    JxlDecoderReleaseJPEGBuffer(dec)
                }
                totalWritten = jpegBuffer.count - unused

            default:
                break
            }
            status = JxlDecoderProcessInput(dec)
        }

        guard status == JXL_DEC_SUCCESS, totalWritten > 0 else { return nil }
        return Data(jpegBuffer.prefix(totalWritten))
    }
}
