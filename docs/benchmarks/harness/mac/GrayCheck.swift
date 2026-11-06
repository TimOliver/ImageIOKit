import Foundation
import CoreGraphics
import ImageIO
@testable import ImageIOKit

func time(_ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    for _ in 0..<12 {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); try body()
        samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
    }
    return samples.sorted()[6]
}
for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let source = ImageSource(data: data)!
    let full = CGRect(origin: .zero, size: source.imageSize)
    var gray: PixelBuffer!
    let tj = try time { gray = try JPEGRegionDecoder(data: data)!.decodeRegion(cropRect: full, pixelFormat: .gray8) }
    let convertGray = try time { _ = try source.converted(gray, to: .gray8) }
    let convertRGBA = try time { _ = try source.converted(gray, to: .rgba8) }
    let imageIO = time {
        let s = CGImageSourceCreateWithData(data as CFData, nil)!
        _ = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    print("\((path as NSString).lastPathComponent): turboJPEGgray=\(String(format: "%.2f", tj))ms space=\(gray.colorSpace.name as String? ?? "ICC") " +
          "convert→gray8=\(String(format: "%.2f", convertGray))ms convert→rgba8=\(String(format: "%.2f", convertRGBA))ms imageIOFullDecode=\(String(format: "%.2f", imageIO))ms")
}
