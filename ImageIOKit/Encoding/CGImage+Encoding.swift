//
//  CGImage+Encoding.swift
//  ImageIOKit
//
//  Internal helper for stripping alpha from CGImages when encoding to opaque formats.
//

import Foundation
import CoreGraphics

extension CGImage {

    /// Returns the image with alpha stripped if it has an alpha channel.
    /// No-op if the image is already opaque.
    func strippingAlpha() -> CGImage {
        let alpha = alphaInfo
        guard alpha != .none, alpha != .noneSkipFirst, alpha != .noneSkipLast else {
            return self
        }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return self
        }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? self
    }
}
