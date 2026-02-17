//
//  MarginDetector.swift
//  ImageIOKit
//
//  Detects blank/uniform-color borders around comic book pages.
//  Works on a small thumbnail (shrink-on-load where available)
//  and reports margins in both thumbnail and full-resolution coordinates.
//

import Foundation
import CoreGraphics
import UIKit

/// Detects uniform-color margins (white/black borders) around images.
public enum MarginDetector {

    /// The maximum thumbnail dimension used for analysis.
    private static let thumbnailMaxDimension: CGFloat = 400

    /// Color distance threshold for considering a pixel "same as margin".
    /// Lower values = stricter matching. Range: 0-255.
    private static let colorThreshold: UInt8 = 30

    /// Minimum fraction of an edge that must match the margin color
    /// for the row/column to be considered part of the margin.
    private static let edgeMatchFraction: Double = 0.90

    /// Detects margins in the given image source.
    /// - Parameter imageSource: A loaded image source.
    /// - Returns: The detected margins, or nil if analysis failed.
    public static func detectMargins(in imageSource: ImageSource) -> ImageMargins? {
        guard imageSource.isLoaded else { return nil }
        let fullSize = imageSource.imageSize

        // Decode a small thumbnail for analysis
        let thumbSize = CGSize(width: thumbnailMaxDimension, height: thumbnailMaxDimension)
        let options = DecodeOptions(targetSize: thumbSize, pixelFormat: .rgba8)
        guard let pixelBuffer = try? imageSource.decode(options: options) else { return nil }

        let thumbWidth = pixelBuffer.width
        let thumbHeight = pixelBuffer.height
        guard thumbWidth > 2, thumbHeight > 2 else { return nil }

        // Sample corner pixels to determine the candidate margin color
        let marginColor = detectMarginColor(pixelBuffer)

        // Scan from each edge inward to find where content begins
        let topRows = scanFromTop(pixelBuffer, marginColor: marginColor)
        let bottomRows = scanFromBottom(pixelBuffer, marginColor: marginColor)
        let leftCols = scanFromLeft(pixelBuffer, marginColor: marginColor)
        let rightCols = scanFromRight(pixelBuffer, marginColor: marginColor)

        // Scale from thumbnail coordinates to full-resolution coordinates
        let scaleX = fullSize.width / CGFloat(thumbWidth)
        let scaleY = fullSize.height / CGFloat(thumbHeight)

        return ImageMargins(
            top: CGFloat(topRows) * scaleY,
            bottom: CGFloat(bottomRows) * scaleY,
            left: CGFloat(leftCols) * scaleX,
            right: CGFloat(rightCols) * scaleX,
            imageSize: fullSize
        )
    }

    // MARK: - Corner Color Detection

    /// Samples the four corners and picks the most common color as the margin candidate.
    private static func detectMarginColor(_ buffer: PixelBuffer) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = buffer.width, h = buffer.height
        let sampleSize = max(1, min(5, min(w, h) / 10))

        // Gather corner samples
        var samples: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for corner in [(0, 0), (w - sampleSize, 0), (0, h - sampleSize), (w - sampleSize, h - sampleSize)] {
            for dy in 0..<sampleSize {
                for dx in 0..<sampleSize {
                    let p = buffer.pixel(at: corner.0 + dx, y: corner.1 + dy)
                    samples.append((p.r, p.g, p.b))
                }
            }
        }

        // Average the samples (good enough for uniform borders)
        guard !samples.isEmpty else { return (255, 255, 255) }
        var rSum = 0, gSum = 0, bSum = 0
        for s in samples { rSum += Int(s.r); gSum += Int(s.g); bSum += Int(s.b) }
        return (UInt8(rSum / samples.count), UInt8(gSum / samples.count), UInt8(bSum / samples.count))
    }

    // MARK: - Edge Scanning

    private static func colorMatches(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                                      _ c: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        abs(Int(p.r) - Int(c.r)) <= Int(colorThreshold) &&
        abs(Int(p.g) - Int(c.g)) <= Int(colorThreshold) &&
        abs(Int(p.b) - Int(c.b)) <= Int(colorThreshold)
    }

    private static func rowIsMargin(_ buffer: PixelBuffer, row: Int,
                                     marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        var matchCount = 0
        for x in 0..<buffer.width {
            if colorMatches(buffer.pixel(at: x, y: row), marginColor) {
                matchCount += 1
            }
        }
        return Double(matchCount) / Double(buffer.width) >= edgeMatchFraction
    }

    private static func columnIsMargin(_ buffer: PixelBuffer, column: Int,
                                        marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        var matchCount = 0
        for y in 0..<buffer.height {
            if colorMatches(buffer.pixel(at: column, y: y), marginColor) {
                matchCount += 1
            }
        }
        return Double(matchCount) / Double(buffer.height) >= edgeMatchFraction
    }

    private static func scanFromTop(_ buffer: PixelBuffer,
                                     marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        for row in 0..<(buffer.height / 2) {
            if !rowIsMargin(buffer, row: row, marginColor: marginColor) { return row }
        }
        return 0
    }

    private static func scanFromBottom(_ buffer: PixelBuffer,
                                        marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        for i in 0..<(buffer.height / 2) {
            let row = buffer.height - 1 - i
            if !rowIsMargin(buffer, row: row, marginColor: marginColor) { return i }
        }
        return 0
    }

    private static func scanFromLeft(_ buffer: PixelBuffer,
                                      marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        for col in 0..<(buffer.width / 2) {
            if !columnIsMargin(buffer, column: col, marginColor: marginColor) { return col }
        }
        return 0
    }

    private static func scanFromRight(_ buffer: PixelBuffer,
                                       marginColor: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        for i in 0..<(buffer.width / 2) {
            let col = buffer.width - 1 - i
            if !columnIsMargin(buffer, column: col, marginColor: marginColor) { return i }
        }
        return 0
    }
}
