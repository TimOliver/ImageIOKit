//
//  BackgroundColorDetector.swift
//  ImageIOKit
//
//  Determines the background color of an image by analyzing
//  its detected margins. Falls back to corner sampling when
//  margins are too narrow.
//

import Foundation
import CoreGraphics
import UIKit

/// The detected background color of an image.
public struct BackgroundColor {
    /// The background color as a UIColor.
    public let color: UIColor

    /// The RGB components (0–255).
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// Confidence level (0.0–1.0) of the detection.
    /// Higher values indicate more consistent margin color.
    public let confidence: Double

    /// Whether the detected color is considered "dark" (for choosing text/UI contrast).
    public var isDark: Bool {
        let luminance = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        return luminance < 128
    }
}

/// Detects the dominant background color of an image.
public enum BackgroundColorDetector {

    /// Minimum margin width (in thumbnail pixels) to use margin-based detection.
    /// Below this threshold, falls back to corner-only sampling.
    private static let minimumMarginPixels = 3

    /// Detects the background color of the given image source.
    /// Uses margin detection first; falls back to corner sampling if margins are too narrow.
    /// - Parameter imageSource: A loaded image source.
    /// - Returns: The detected background color, or nil if analysis failed.
    public static func detectBackgroundColor(in imageSource: ImageSource) -> BackgroundColor? {
        guard imageSource.isLoaded else { return nil }

        // Decode a small thumbnail
        let thumbSize = CGSize(width: 400, height: 400)
        let options = DecodeOptions(targetSize: thumbSize, pixelFormat: .rgba8)
        guard let pixelBuffer = try? imageSource.decode(options: options) else { return nil }

        // Try margin-based detection first
        if let margins = MarginDetector.detectMargins(in: imageSource), margins.hasMargins {
            let thumbScaleX = CGFloat(pixelBuffer.width) / imageSource.imageSize.width
            let thumbScaleY = CGFloat(pixelBuffer.height) / imageSource.imageSize.height

            let thumbTop = Int(margins.top * thumbScaleY)
            let thumbBottom = Int(margins.bottom * thumbScaleY)
            let thumbLeft = Int(margins.left * thumbScaleX)
            let thumbRight = Int(margins.right * thumbScaleX)

            let hasWidthMargin = thumbLeft >= minimumMarginPixels || thumbRight >= minimumMarginPixels
            let hasHeightMargin = thumbTop >= minimumMarginPixels || thumbBottom >= minimumMarginPixels

            if hasWidthMargin || hasHeightMargin {
                return sampleMarginColor(pixelBuffer,
                                         top: thumbTop, bottom: thumbBottom,
                                         left: thumbLeft, right: thumbRight)
            }
        }

        // Fall back to corner-only sampling
        return sampleCornerColor(pixelBuffer)
    }

    // MARK: - Margin Color Sampling

    /// Samples the color within the detected margin regions.
    private static func sampleMarginColor(_ buffer: PixelBuffer,
                                           top: Int, bottom: Int,
                                           left: Int, right: Int) -> BackgroundColor? {
        var rSum: Int = 0, gSum: Int = 0, bSum: Int = 0
        var count = 0
        var rSqSum: Double = 0, gSqSum: Double = 0, bSqSum: Double = 0

        let stride = max(1, min(buffer.width, buffer.height) / 100) // Sample every Nth pixel

        // Sample top margin
        for y in Swift.stride(from: 0, to: min(top, buffer.height), by: stride) {
            for x in Swift.stride(from: 0, to: buffer.width, by: stride) {
                addSample(buffer.pixel(at: x, y: y), &rSum, &gSum, &bSum,
                          &rSqSum, &gSqSum, &bSqSum, &count)
            }
        }

        // Sample bottom margin
        for y in Swift.stride(from: max(0, buffer.height - bottom), to: buffer.height, by: stride) {
            for x in Swift.stride(from: 0, to: buffer.width, by: stride) {
                addSample(buffer.pixel(at: x, y: y), &rSum, &gSum, &bSum,
                          &rSqSum, &gSqSum, &bSqSum, &count)
            }
        }

        // Sample left margin (between top and bottom)
        let yStart = min(top, buffer.height)
        let yEnd = max(0, buffer.height - bottom)
        for y in Swift.stride(from: yStart, to: yEnd, by: stride) {
            for x in Swift.stride(from: 0, to: min(left, buffer.width), by: stride) {
                addSample(buffer.pixel(at: x, y: y), &rSum, &gSum, &bSum,
                          &rSqSum, &gSqSum, &bSqSum, &count)
            }
        }

        // Sample right margin (between top and bottom)
        for y in Swift.stride(from: yStart, to: yEnd, by: stride) {
            for x in Swift.stride(from: max(0, buffer.width - right), to: buffer.width, by: stride) {
                addSample(buffer.pixel(at: x, y: y), &rSum, &gSum, &bSum,
                          &rSqSum, &gSqSum, &bSqSum, &count)
            }
        }

        return buildResult(rSum: rSum, gSum: gSum, bSum: bSum,
                           rSqSum: rSqSum, gSqSum: gSqSum, bSqSum: bSqSum, count: count)
    }

    // MARK: - Corner Sampling Fallback

    /// Samples small patches at the four corners when margins are too narrow.
    private static func sampleCornerColor(_ buffer: PixelBuffer) -> BackgroundColor? {
        let w = buffer.width, h = buffer.height
        let patchSize = max(1, min(10, min(w, h) / 10))

        var rSum: Int = 0, gSum: Int = 0, bSum: Int = 0
        var count = 0
        var rSqSum: Double = 0, gSqSum: Double = 0, bSqSum: Double = 0

        let corners = [(0, 0), (w - patchSize, 0), (0, h - patchSize), (w - patchSize, h - patchSize)]
        for (cx, cy) in corners {
            for dy in 0..<patchSize {
                for dx in 0..<patchSize {
                    addSample(buffer.pixel(at: cx + dx, y: cy + dy),
                              &rSum, &gSum, &bSum, &rSqSum, &gSqSum, &bSqSum, &count)
                }
            }
        }

        return buildResult(rSum: rSum, gSum: gSum, bSum: bSum,
                           rSqSum: rSqSum, gSqSum: gSqSum, bSqSum: bSqSum, count: count)
    }

    // MARK: - Helpers

    private static func addSample(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                                    _ rSum: inout Int, _ gSum: inout Int, _ bSum: inout Int,
                                    _ rSqSum: inout Double, _ gSqSum: inout Double, _ bSqSum: inout Double,
                                    _ count: inout Int) {
        rSum += Int(p.r); gSum += Int(p.g); bSum += Int(p.b)
        rSqSum += Double(p.r) * Double(p.r)
        gSqSum += Double(p.g) * Double(p.g)
        bSqSum += Double(p.b) * Double(p.b)
        count += 1
    }

    private static func buildResult(rSum: Int, gSum: Int, bSum: Int,
                                     rSqSum: Double, gSqSum: Double, bSqSum: Double,
                                     count: Int) -> BackgroundColor? {
        guard count > 0 else { return nil }

        let r = UInt8(clamping: rSum / count)
        let g = UInt8(clamping: gSum / count)
        let b = UInt8(clamping: bSum / count)

        // Compute confidence from variance — low variance = high confidence
        let rVar = rSqSum / Double(count) - pow(Double(rSum) / Double(count), 2)
        let gVar = gSqSum / Double(count) - pow(Double(gSum) / Double(count), 2)
        let bVar = bSqSum / Double(count) - pow(Double(bSum) / Double(count), 2)
        let avgStdDev = sqrt((rVar + gVar + bVar) / 3.0)
        let confidence = max(0, min(1, 1.0 - avgStdDev / 128.0))

        let color = UIColor(red: CGFloat(r) / 255.0,
                             green: CGFloat(g) / 255.0,
                             blue: CGFloat(b) / 255.0,
                             alpha: 1.0)

        return BackgroundColor(color: color, red: r, green: g, blue: b, confidence: confidence)
    }
}
