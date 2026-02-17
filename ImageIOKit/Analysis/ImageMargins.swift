//
//  ImageMargins.swift
//  ImageIOKit
//

import Foundation
import CoreGraphics

/// Detected margins around an image.
public struct ImageMargins {
    /// Top margin in pixels (full-resolution coordinates).
    public let top: CGFloat
    /// Bottom margin in pixels (full-resolution coordinates).
    public let bottom: CGFloat
    /// Left margin in pixels (full-resolution coordinates).
    public let left: CGFloat
    /// Right margin in pixels (full-resolution coordinates).
    public let right: CGFloat

    /// The content rect after removing margins, in full-resolution coordinates.
    public var contentRect: CGRect {
        CGRect(x: left, y: top,
               width: max(0, imageSize.width - left - right),
               height: max(0, imageSize.height - top - bottom))
    }

    /// The full image size these margins were computed for.
    public let imageSize: CGSize

    /// Whether any margin was detected.
    public var hasMargins: Bool {
        top > 0 || bottom > 0 || left > 0 || right > 0
    }
}
