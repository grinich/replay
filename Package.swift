// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Replay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Replay", targets: ["Replay"])
    ],
    targets: [
        .executableTarget(
            name: "Replay",
            path: "Sources/Replay"
        )
    ],
    swiftLanguageVersions: [.v5]
)
