//
//  ImageIOKitTestsCommon.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation

/// A class for managing accessing the photos of Apple Park
/// used in testing and benchmarking this framework.
public final class ImageSampleData {

    /// The formats where a valid test image is available.
    public enum Format: String, CaseIterable {
        case jpeg = "jpeg"
        case png = "png"
        case webp = "webp"
        case heic = "heic"
        case avif = "avif"
        case jpegXL = "jxl"
    }

    // Fetch the absolute URL of the image data for the desired format.
    static func urlForTestImage(with format: Format) -> URL {
        guard let bundleURL = Bundle(for: Self.self).resourceURL else {
            fatalError("Unable to find main bundle")
        }
        return bundleURL.appendingPathComponent("ApplePark.\(format.rawValue)")
    }
}
