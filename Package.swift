// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-git",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Git", targets: ["Git", "CGit2", "GitInit"])
    ],
    targets: [
        .target(
            name: "Git",
            dependencies: ["GitInit"],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
        .target(
            name: "GitInit",
            dependencies: ["CGit2"],
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "CGit2",
            path: "CGit2.xcframework"
        ),
        .testTarget(
            name: "GitTests",
            dependencies: ["Git"]
        ),
    ]
)
