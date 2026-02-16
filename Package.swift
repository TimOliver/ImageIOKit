// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImageIOKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ImageIOKit", targets: ["ImageIOKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SusanDoggie/libjpeg.git", from: "1.0.3"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
        .package(url: "https://github.com/awxkee/avif.swift.git", from: "2.1.2"),
        .package(url: "https://github.com/SDWebImage/libjxl-Xcode.git", from: "0.10.4"),
    ],
    targets: [
        .target(
            name: "ImageIOKit",
            dependencies: [
                "libjpeg",
                .product(name: "libwebp", package: "libwebp-Xcode"),
                .product(name: "avif", package: "avif.swift"),
                .product(name: "libjxl", package: "libjxl-Xcode"),
                "CLibspng",
            ],
            path: "ImageIOKit",
            exclude: ["Vendor"]
        ),
        .target(
            name: "CLibspng",
            path: "ImageIOKit/Vendor/libspng",
            sources: ["spng.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
    ]
)
