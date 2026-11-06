import Foundation
import CoreGraphics
@testable import ImageIOKit

// For each JXL: native thumbnail for a 2048 bound, then the library-style CG resample.
// Prints the color space, a pixel checksum (tagging must not change pixels) and CG time.
for path in CommandLine.arguments.dropFirst() {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JXLDecoder(data: data)!
    let source = CGSize(width: decoder.imageSize.width, height: decoder.imageSize.height)
    let size = try! SoftwareScaler.outputSize(for: source, fitting: CGSize(width: 2048, height: 2048))
    let native = try! decoder.decodeThumbnail(fittingSize: size)
    var checksum: UInt64 = 1469598103934665603
    let bytes = native.data.assumingMemoryBound(to: UInt8.self)
    for i in 0..<native.dataSize { checksum = (checksum ^ UInt64(bytes[i])) &* 1099511628211 }
    var times: [Double] = []
    for _ in 0..<9 {
        let output = PixelBuffer(width: Int(size.width), height: Int(size.height), pixelFormat: .rgba8)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let context = CGContext(data: output.data, width: output.width, height: output.height, bitsPerComponent: 8,
                                bytesPerRow: output.bytesPerRow, space: output.colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(native.makeCGImage()!, in: CGRect(origin: .zero, size: size))
        times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
    }
    times.sort()
    print(String(format: "%@ native=%dx%d cgMedian=%.1fms checksum=%016llx", (path as NSString).lastPathComponent,
                 native.width, native.height, times[4], checksum),
          "space=\(native.colorSpace.name as String? ?? "unnamed ICC")")
}
