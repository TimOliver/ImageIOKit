//
//  ImageColorModel.swift
//  ImageIOKit
//
//  Created by Tim Oliver on 1/1/2026.
//

import Foundation
import CoreFoundation
import ImageIO

/// The types of color modes in which an image may be encoded.
public enum ImageColorModel {
    case rgb
    case grayscale
    case cmyk
    case lab

    internal init?(colorModel: String) {
        switch (colorModel as CFString) {
        case kCGImagePropertyColorModelRGB: self = .rgb
        case kCGImagePropertyColorModelGray: self = .grayscale
        case kCGImagePropertyColorModelCMYK: self = .cmyk
        case kCGImagePropertyColorModelLab: self = .lab
        default: return nil
        }
    }
}

