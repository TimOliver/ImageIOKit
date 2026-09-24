//
//  JXLReconstructor.swift
//  ImageIOKit
//
//  Lossless JPEG reconstruction from JXL files using libjxl.
//  For JXL files that were created by losslessly recompressing a JPEG,
//  this reconstructs the exact original JPEG bitstream.
//

import Foundation
import jxl

struct JXLReconstructor {

    private let imageData: Data

    /// Creates a reconstructor from in-memory JXL data.
    /// - Parameter data: The compressed JXL data.
    /// - Returns: `nil` if the data is empty.
    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        self.imageData = data
    }

    /// Creates a reconstructor from a JXL file on disk.
    /// - Parameter url: A local file URL to a JXL file.
    /// - Returns: `nil` if the file cannot be read.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    /// Attempts to reconstruct the original JPEG bitstream from a JXL file
    /// that was created by losslessly recompressing a JPEG. Returns the exact
    /// original JPEG bytes, or `nil` if the JXL was not derived from a JPEG.
    func reconstructJPEG() -> Data? {
        return imageData.withUnsafeBytes { bufferPtr in
            guard let dec = JxlDecoderCreate(nil) else { return nil }
            defer { JxlDecoderDestroy(dec) }

            let events = Int32(JXL_DEC_JPEG_RECONSTRUCTION.rawValue
                             | JXL_DEC_FULL_IMAGE.rawValue)
            guard JxlDecoderSubscribeEvents(dec, events) == JXL_DEC_SUCCESS else {
                return nil
            }

            guard let baseAddress = bufferPtr.baseAddress,
                  JxlDecoderSetInput(dec, baseAddress.assumingMemoryBound(to: UInt8.self), bufferPtr.count) == JXL_DEC_SUCCESS else { return nil }
            JxlDecoderCloseInput(dec)

            // Use manually managed buffers so pointers stay stable across
            // JxlDecoderProcessInput calls (Swift Array storage can relocate).
            var bufferSize = max(imageData.count * 2, 65536)
            var jpegBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { _ = JxlDecoderReleaseJPEGBuffer(dec); jpegBuffer.deallocate() }
            var totalWritten = 0

            var status = JxlDecoderProcessInput(dec)
            while status != JXL_DEC_SUCCESS && status != JXL_DEC_ERROR {
                switch status {
                case JXL_DEC_JPEG_RECONSTRUCTION:
                    // JXL contains JPEG reconstruction data — set the output buffer.
                    // Must be set here (after the decoder reaches this state), before
                    // JXL_DEC_NEED_IMAGE_OUT_BUFFER can fire. With the JPEG buffer
                    // set, the decoder writes JPEG bytes instead of requesting pixels.
                    guard JxlDecoderSetJPEGBuffer(dec, jpegBuffer, bufferSize) == JXL_DEC_SUCCESS else {
                        return nil
                    }

                case JXL_DEC_JPEG_NEED_MORE_OUTPUT:
                    // Buffer too small — release, grow, and re-set remaining space
                    let unused = JxlDecoderReleaseJPEGBuffer(dec)
                    totalWritten = bufferSize - unused

                    let newSize = bufferSize * 2
                    let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newSize)
                    newBuffer.update(from: jpegBuffer, count: totalWritten)
                    jpegBuffer.deallocate()
                    jpegBuffer = newBuffer
                    bufferSize = newSize

                    guard JxlDecoderSetJPEGBuffer(dec, jpegBuffer + totalWritten, bufferSize - totalWritten) == JXL_DEC_SUCCESS else {
                        return nil
                    }

                case JXL_DEC_FULL_IMAGE:
                    // Reconstruction complete
                    let unused = JxlDecoderReleaseJPEGBuffer(dec)
                    totalWritten = bufferSize - unused

                default:
                    // JXL_DEC_NEED_IMAGE_OUT_BUFFER means the file was not created
                    // from a JPEG — reconstruction is not possible.
                    return nil
                }
                status = JxlDecoderProcessInput(dec)
            }

            guard status == JXL_DEC_SUCCESS, totalWritten > 0 else {
                return nil
            }
            return Data(bytes: jpegBuffer, count: totalWritten)
        }
    }
}
