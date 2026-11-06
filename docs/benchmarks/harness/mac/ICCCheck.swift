import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import turbojpeg

func jpeg(space: CGColorSpace, gray: Bool) -> Data {
    let w = 64, h = 64
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray ? CGColor(gray: 0.5, alpha: 1) : CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// Corrupts the ICC_PROFILE APP2 chunk header's sequence number (byte after "ICC_PROFILE\0").
func corruptICC(_ data: Data) -> Data? {
    var bytes = [UInt8](data)
    let tag = Array("ICC_PROFILE".utf8) + [0]
    guard let i = (0..<(bytes.count - tag.count)).first(where: { Array(bytes[$0..<$0 + tag.count]) == tag }) else { return nil }
    bytes[i + tag.count] = 0   // sequence number 0 is invalid
    return Data(bytes)
}

func probe(_ name: String, _ data: Data) {
    let handle = tj3Init(Int32(TJINIT_DECOMPRESS.rawValue))!
    defer { tj3Destroy(handle) }
    tj3Set(handle, Int32(TJPARAM_SAVEMARKERS.rawValue), 4)
    let header = data.withUnsafeBytes { tj3DecompressHeader(handle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }
    var size = 0
    let sizeOnly = tj3GetICCProfile(handle, nil, &size)
    let sizeMessage = String(cString: tj3GetErrorStr(handle)), sizeCode = tj3GetErrorCode(handle)
    var bytes: UnsafeMutablePointer<UInt8>?
    var count = 0
    let status = tj3GetICCProfile(handle, &bytes, &count)
    let message = String(cString: tj3GetErrorStr(handle)), code = tj3GetErrorCode(handle)
    let space = bytes.flatMap { CGColorSpace(iccData: Data(bytes: $0, count: count) as CFData) }
    print("\(name): header=\(header) sizeOnly=\(sizeOnly) size=\(size) code=\(sizeCode) '\(sizeMessage)' | get=\(status) buffer=\(bytes != nil) count=\(count) code=\(code) '\(message)' space=\(space?.name as String? ?? "nil")")
    if let bytes { tj3Free(bytes) }
    // Second retrieval: docs say the profile must be re-extracted first.
    var again: UnsafeMutablePointer<UInt8>?
    var againCount = 0
    let second = tj3GetICCProfile(handle, &again, &againCount)
    print("   second get=\(second) buffer=\(again != nil) '\(String(cString: tj3GetErrorStr(handle)))'")
    if let again { tj3Free(again) }
    let imageIO = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    print("   ImageIO colorspace=\(imageIO?.colorSpace?.name as String? ?? "nil")")
}

let srgbPlain = jpeg(space: CGColorSpace(name: CGColorSpace.sRGB)!, gray: false)
let p3 = jpeg(space: CGColorSpace(name: CGColorSpace.displayP3)!, gray: false)
probe("sRGB (as ImageIO writes it)", srgbPlain)
probe("Display P3", p3)
probe("DeviceGray", jpeg(space: CGColorSpaceCreateDeviceGray(), gray: true))
if let broken = corruptICC(p3) { probe("Display P3, corrupt ICC chunk", broken) } else { print("P3 has no ICC chunk?") }
