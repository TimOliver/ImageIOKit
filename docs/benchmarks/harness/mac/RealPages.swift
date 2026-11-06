import Foundation
import CoreGraphics
import Metal
@testable import ImageIOKit

// Real comic pages: metadata, then median timings for decode(targetSize:) and makeTexture at screen sizes.
let device = MTLCreateSystemDefaultDevice()!
let scaler = TextureScaler(device: device)!
let screens: [(String, CGSize)] = [("iPhoneSE", CGSize(width: 750, height: 1334)),
                                   ("iPhoneProMax", CGSize(width: 1320, height: 2868)),
                                   ("iPad13", CGSize(width: 2064, height: 2752))]
final class Box: @unchecked Sendable {
    let source: ImageSource, screen: CGSize, format: PixelBuffer.PixelFormat, scaler: TextureScaler
    var texture: MTLTexture?, error: Error?
    init(_ source: ImageSource, _ screen: CGSize, _ format: PixelBuffer.PixelFormat, _ scaler: TextureScaler) {
        self.source = source; self.screen = screen; self.format = format; self.scaler = scaler
    }
}

func ms(_ body: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); try body()
    return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
}
func median(_ values: [Double]) -> String { String(format: "%.2f", values.sorted()[values.count / 2]) }

for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let source = ImageSource(data: data)!
    print("\n\((path as NSString).lastPathComponent): \(Int(source.imageSize.width))x\(Int(source.imageSize.height)) " +
          "format=\(source.fileFormat.map { "\($0)" } ?? "nil") model=\(source.colorModel.map { "\($0)" } ?? "nil") " +
          "profile=\(source.colorProfile ?? "nil") regionDecodable=\(source.isRegionDecodable)")
    let formats: [PixelBuffer.PixelFormat] = source.colorModel == .grayscale ? [.gray8, .rgba8] : [.rgba8]
    for (name, screen) in screens {
        for format in formats {
            var decodeTimes: [Double] = [], textureTimes: [Double] = []
            var output = ""
            for iteration in 0..<12 {
                var buffer: PixelBuffer?
                let d = try ms { buffer = try ImageSource(data: data)!.decode(targetSize: screen, pixelFormat: format) }
                var box: Box!
                let t = ms {
                    let done = DispatchSemaphore(value: 0)
                    let call = Box(ImageSource(data: data)!, screen, format, scaler)
                    box = call
                    Task.detached {
                        do { call.texture = try await call.source.makeTexture(fitting: call.screen, pixelFormat: call.format, using: call.scaler) }
                        catch { call.error = error }
                        done.signal()
                    }
                    done.wait()
                }
                if let error = box.error { print("  ERROR \(error)") }
                if iteration > 1 { decodeTimes.append(d); textureTimes.append(t) }
                output = "\(buffer!.width)x\(buffer!.height)"
                precondition(box.texture!.width == buffer!.width && box.texture!.height == buffer!.height)
            }
            print("  \(name) \(format): output=\(output) decode(targetSize:)=\(median(decodeTimes))ms makeTexture=\(median(textureTimes))ms")
        }
    }
}
