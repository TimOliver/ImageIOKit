// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImageIOKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ImageIOKit", targets: ["ImageIOKit"]),
    ],
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
            path: "ImageIOKit",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(
            name: "ImageIOKitTests",
            dependencies: ["ImageIOKit", .product(name: "jxl", package: "libjxl-cocoa")],
            path: "ImageIOKitTests",
            resources: [.copy("SampleImages")]
        ),
    ]
)
