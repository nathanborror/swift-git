# Swift Git

An unofficial Swift client for interacting with Git. ⚠️ _Caution: Thrashy project, fork if you wanna use._ ⚠️

## Requirements

- Swift 5.9+
- iOS 17+
- macOS 14+

## Installation

Add the following to your `Package.swift` file:

```swift
Package(
    dependencies: [
        .package(url: "https://github.com/nathanborror/swift-git", branch: "main"),
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "Git", package: "swift-git"),
            ]
        ),
    ]
)
```

## Inspiration

These repos have been helpful to understand how to pull this together. Swift Git is basically a fork of AsyncSwiftGit 
with a lot of stylistic changes for better or worse.

- [bdewey/static-libgit2](https://github.com/bdewey/static-libgit2)
- [bdewey/AsyncSwiftGit](https://github.com/bdewey/AsyncSwiftGit)
- [light-tech/MiniGit](https://github.com/light-tech/MiniGit)
