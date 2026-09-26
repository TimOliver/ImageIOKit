//
//  WebPImageDecoder.swift
//  ImageIOKit
//

import Foundation
import CoreGraphics
import WebPDecoder
import WebPDemux

/// Decodes upright still WebP images directly into a scaled, premultiplied buffer.
/// Lossless and alpha decoding may still need source-sized codec working storage.
struct WebPImageDecoder {
    private let imageData: Data
    let imageSize: CGSize
    private let isLossless: Bool

    init?(data: Data) {
        var features = WebPBitstreamFeatures()
        let status = data.withUnsafeBytes { bytes in
            WebPGetFeatures(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &features)
        }
        guard status == VP8_STATUS_OK, features.width > 0, features.height > 0,
              features.has_animation == 0 else { return nil }
        imageData = data
        imageSize = CGSize(width: Int(features.width), height: Int(features.height))
        isLossless = features.format == 2
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    /// Odd-origin lossy crops must use the caller's exact-crop fallback, since
    /// libwebp snaps YUV crop origins down to even coordinates before scaling.
    func decode(targetSize: CGSize? = nil, cropRect: CGRect? = nil) throws -> PixelBuffer {
        let crop = try cropRect.map { try SoftwareScaler.clampedCrop($0, in: imageSize) }
        if let crop, !isLossless, Int(crop.minX) % 2 != 0 || Int(crop.minY) % 2 != 0 {
            throw ImageDecoderError.unsupportedOperation
        }
        let size = try SoftwareScaler.outputSize(for: crop?.size ?? imageSize, fitting: targetSize)

        // Demux chunk pointers borrow the input. Destroy the demuxer and decoder
        // output before leaving this borrow, even when decoding throws.
        return try imageData.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self).baseAddress
            var data = WebPData(bytes: input, size: bytes.count)
            guard let demuxer = WebPDemux(&data) else { throw ImageDecoderError.invalidData }
            defer { WebPDemuxDelete(demuxer) }

            var colorSpace = PixelBuffer.defaultColorSpace(for: .rgba8)
            var profile = WebPChunkIterator()
            if WebPDemuxGetChunk(demuxer, "ICCP", 1, &profile) != 0 {
                defer { WebPDemuxReleaseChunkIterator(&profile) }
                guard let profileBytes = profile.chunk.bytes else { throw ImageDecoderError.invalidData }
                let icc = Data(bytes: profileBytes, count: profile.chunk.size)
                guard let embedded = CGColorSpace(iccData: icc as CFData), embedded.model == .rgb else {
                    throw ImageDecoderError.unsupportedOperation
                }
                colorSpace = embedded
            }

            var config = WebPDecoderConfig()
            guard WebPInitDecoderConfig(&config) != 0 else {
                throw ImageDecoderError.decodeFailed("Failed to initialize WebP decoder")
            }
            defer { WebPFreeDecBuffer(&config.output) }
            if let crop {
                config.options.use_cropping = 1
                config.options.crop_left = Int32(crop.minX)
                config.options.crop_top = Int32(crop.minY)
                config.options.crop_width = Int32(crop.width)
                config.options.crop_height = Int32(crop.height)
            }
            config.options.use_scaling = size != (crop?.size ?? imageSize) ? 1 : 0
            config.options.scaled_width = Int32(size.width)
            config.options.scaled_height = Int32(size.height)
            config.options.use_threads = 1

            let output = PixelBuffer(width: Int(size.width), height: Int(size.height),
                                     pixelFormat: .rgba8, colorSpace: colorSpace)
            config.output.colorspace = MODE_rgbA
            config.output.is_external_memory = 1
            config.output.u.RGBA.rgba = output.data.assumingMemoryBound(to: UInt8.self)
            config.output.u.RGBA.stride = Int32(output.bytesPerRow)
            config.output.u.RGBA.size = output.dataSize
            let status = WebPDecode(input, bytes.count, &config)
            guard status == VP8_STATUS_OK else {
                throw ImageDecoderError.decodeFailed("WebP decoding failed (status \(status.rawValue))")
            }
            return output
        }
    }
}
