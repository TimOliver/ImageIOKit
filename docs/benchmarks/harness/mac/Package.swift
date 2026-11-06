// swift-tools-version: 6.0
// Benchmark harness: a copy of the library built natively for macOS with testability, plus probes.
// Created by setup-mac.sh; see README.md.
import PackageDescription

let package = Package(
    name: "GPUScaleBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/TimOliver/libjpeg-turbo-cocoa.git", from: "3.1.3"),
        .package(url: "https://github.com/TimOliver/libjxl-cocoa.git", from: "0.11.2"),
        .package(url: "https://github.com/TimOliver/WebP-Cocoa.git", from: "1.6.1"),
    ],
    targets: [
        .target(
            name: "ImageIOKit",
            dependencies: [
                .product(name: "turbojpeg", package: "libjpeg-turbo-cocoa"),
                .product(name: "jxl", package: "libjxl-cocoa"),
                .product(name: "WebPDecoding", package: "WebP-Cocoa"),
            ],
            swiftSettings: [.unsafeFlags(["-enable-testing"])],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(
            name: "GrayCheck",
            dependencies: ["ImageIOKit"]
        ),
        .executableTarget(
            name: "RealPages",
            dependencies: ["ImageIOKit"]
        ),
        .executableTarget(
            name: "BoxCheck",
            dependencies: ["ImageIOKit"]
        ),
        .executableTarget(
            name: "ICCCheck",
            dependencies: [.product(name: "turbojpeg", package: "libjpeg-turbo-cocoa")]
        ),
        .executableTarget(
            name: "GPUScaleBench",
            dependencies: ["ImageIOKit", .product(name: "jxl", package: "libjxl-cocoa")]
        ),
    ]
)
