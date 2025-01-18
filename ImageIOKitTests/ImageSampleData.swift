//
//  ImageIOKitTestsCommon.swift
//  ImageIOKitTests
//
//  Created by Tim Oliver on 17/1/2025.
//

import Foundation

public final class ImageSampleData {

    public enum Format: String, CaseIterable {
        case jpeg = "jpeg"
        case png = "png"
        case webp = "webp"
        case heic = "heic"
    }

    static func urlForTestImage(with format: Format) -> URL {
        guard let bundleURL = Bundle(for: Self.self).resourceURL else {
            fatalError("Unable to find main bundle")
        }
        return bundleURL.appendingPathComponent("ApplePark.\(format.rawValue)")
    }

}
