//
//  BackgroundColor.swift
//  ImageIOKit
//

import Foundation
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
        let luminance = 299 * Int(red) + 587 * Int(green) + 114 * Int(blue)
        return luminance < 128_000
    }
}
