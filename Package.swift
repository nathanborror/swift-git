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
        .library(name: "Git", targets: ["CGit2", "Git"])
    ],
    targets: [
        .binaryTarget(name: "CGit2", path: "CGit2.xcframework"),
        .target(name: "Git", linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
    ]
)
