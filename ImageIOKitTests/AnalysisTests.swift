//
//  AnalysisTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class AnalysisTests: XCTestCase {

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
    }

    // MARK: - MarginDetector

    func testMarginDetectorAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let margins = MarginDetector.detectMargins(in: source)
                XCTAssertNotNil(margins, "MarginDetector returned nil for \(format)")
            }
        }
    }

    func testMarginContentRectWithinBounds() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                guard let margins = MarginDetector.detectMargins(in: source) else {
                    XCTFail("MarginDetector returned nil for \(format)")
                    return
                }
                let contentRect = margins.contentRect
                let imageBounds = CGRect(origin: .zero, size: source.imageSize)
                XCTAssertTrue(imageBounds.contains(contentRect) ||
                              contentRect.width == 0 || contentRect.height == 0,
                              "\(format): contentRect \(contentRect) outside image bounds \(imageBounds)")
            }
        }
    }

    func testMarginValuesAreNonNegative() {
        let source = makeSource(for: .jpeg)
        guard let margins = MarginDetector.detectMargins(in: source) else {
            XCTFail("MarginDetector returned nil")
            return
        }
        XCTAssertGreaterThanOrEqual(margins.top, 0)
        XCTAssertGreaterThanOrEqual(margins.bottom, 0)
        XCTAssertGreaterThanOrEqual(margins.left, 0)
        XCTAssertGreaterThanOrEqual(margins.right, 0)
    }

    func testMarginImageSizeMatchesSource() {
        let source = makeSource(for: .jpeg)
        guard let margins = MarginDetector.detectMargins(in: source) else {
            XCTFail("MarginDetector returned nil")
            return
        }
        XCTAssertEqual(margins.imageSize.width, source.imageSize.width)
        XCTAssertEqual(margins.imageSize.height, source.imageSize.height)
    }

    func testMarginDetectorWithUnloadedSource() {
        let url = ImageSampleData.urlForTestImage(with: .jpeg)
        guard let source = ImageSource(url: url, loadImmediately: false) else {
            XCTFail("Failed to create deferred source")
            return
        }
        let margins = MarginDetector.detectMargins(in: source)
        XCTAssertNil(margins, "Should return nil for unloaded source")
    }

    // MARK: - BackgroundColorDetector

    func testBackgroundColorDetectorAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let bgColor = BackgroundColorDetector.detectBackgroundColor(in: source)
                XCTAssertNotNil(bgColor, "BackgroundColorDetector returned nil for \(format)")
            }
        }
    }

    func testBackgroundColorConfidenceRange() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                guard let bgColor = BackgroundColorDetector.detectBackgroundColor(in: source) else {
                    XCTFail("BackgroundColorDetector returned nil for \(format)")
                    return
                }
                XCTAssertGreaterThanOrEqual(bgColor.confidence, 0.0,
                                             "\(format) confidence below 0")
                XCTAssertLessThanOrEqual(bgColor.confidence, 1.0,
                                          "\(format) confidence above 1")
            }
        }
    }

    func testBackgroundColorIsDarkComputation() {
        // Black → dark
        let black = BackgroundColor(color: .black, red: 0, green: 0, blue: 0, confidence: 1.0)
        XCTAssertTrue(black.isDark)

        // White → not dark
        let white = BackgroundColor(color: .white, red: 255, green: 255, blue: 255, confidence: 1.0)
        XCTAssertFalse(white.isDark)

        // Midpoint: luminance = 0.299*128 + 0.587*128 + 0.114*128 = 128
        // 128 is at the boundary (luminance < 128 → dark), so 128 is NOT dark
        let mid = BackgroundColor(color: .gray, red: 128, green: 128, blue: 128, confidence: 1.0)
        XCTAssertFalse(mid.isDark)

        // Just below midpoint
        let darkish = BackgroundColor(color: .darkGray, red: 50, green: 50, blue: 50, confidence: 1.0)
        XCTAssertTrue(darkish.isDark)
    }

    func testBackgroundColorConsistentAcrossFormats() {
        // All formats should detect similar background colors for the same image
        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []

        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                guard let bgColor = BackgroundColorDetector.detectBackgroundColor(in: source) else {
                    return
                }
                reds.append(bgColor.red)
                greens.append(bgColor.green)
                blues.append(bgColor.blue)
            }
        }

        guard reds.count >= 2 else { return }

        // Colors should be reasonably similar across formats (within ~30 of each other)
        let tolerance: UInt8 = 40
        for i in 1..<reds.count {
            XCTAssertLessThanOrEqual(abs(Int(reds[i]) - Int(reds[0])), Int(tolerance),
                "Red channel diverged significantly across formats")
            XCTAssertLessThanOrEqual(abs(Int(greens[i]) - Int(greens[0])), Int(tolerance),
                "Green channel diverged significantly across formats")
            XCTAssertLessThanOrEqual(abs(Int(blues[i]) - Int(blues[0])), Int(tolerance),
                "Blue channel diverged significantly across formats")
        }
    }

    func testBackgroundColorDetectorWithUnloadedSource() {
        let url = ImageSampleData.urlForTestImage(with: .jpeg)
        guard let source = ImageSource(url: url, loadImmediately: false) else {
            XCTFail("Failed to create deferred source")
            return
        }
        let bgColor = BackgroundColorDetector.detectBackgroundColor(in: source)
        XCTAssertNil(bgColor, "Should return nil for unloaded source")
    }

    // MARK: - ImageMargins Properties

    func testImageMarginsHasMargins() {
        let noMargins = ImageMargins(top: 0, bottom: 0, left: 0, right: 0,
                                      imageSize: CGSize(width: 100, height: 100))
        XCTAssertFalse(noMargins.hasMargins)

        let withMargins = ImageMargins(top: 10, bottom: 0, left: 0, right: 5,
                                        imageSize: CGSize(width: 100, height: 100))
        XCTAssertTrue(withMargins.hasMargins)
    }

    func testImageMarginsContentRect() {
        let margins = ImageMargins(top: 10, bottom: 20, left: 5, right: 15,
                                    imageSize: CGSize(width: 200, height: 300))
        let rect = margins.contentRect
        XCTAssertEqual(rect.origin.x, 5)
        XCTAssertEqual(rect.origin.y, 10)
        XCTAssertEqual(rect.width, 180)  // 200 - 5 - 15
        XCTAssertEqual(rect.height, 270)  // 300 - 10 - 20
    }

    func testImageMarginsContentRectDoesNotGoNegative() {
        let huge = ImageMargins(top: 200, bottom: 200, left: 200, right: 200,
                                 imageSize: CGSize(width: 100, height: 100))
        let rect = huge.contentRect
        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 0)
    }
}
