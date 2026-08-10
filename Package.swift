// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WatchLater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WatchLater", targets: ["WatchLater"])
    ],
    targets: [
        .executableTarget(
            name: "WatchLater",
            path: "Sources/WatchLater"
        )
    ],
    swiftLanguageVersions: [.v5]
)
