// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImageIOKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ImageIOKit", targets: ["ImageIOKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/TimOliver/libjpeg-turbo-cocoa.git", from: "3.1.3"),
        .package(url: "https://github.com/SDWebImage/libjxl-Xcode.git", from: "0.10.4"),
    ],
    targets: [
        .target(
            name: "ImageIOKit",
            dependencies: [
                .product(name: "libjpeg-ios", package: "libjpeg-turbo-cocoa"),
                .product(name: "libjxl", package: "libjxl-Xcode"),
            ],
            path: "ImageIOKit",
            exclude: ["Vendor"]
        ),
    ]
)
