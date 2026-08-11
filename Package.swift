// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Rewatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Rewatch", targets: ["Rewatch"])
    ],
    targets: [
        .executableTarget(
            name: "Rewatch",
            path: "Sources/Rewatch"
        )
    ],
    swiftLanguageVersions: [.v5]
)
