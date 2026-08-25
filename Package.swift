// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Replay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Replay", targets: ["Replay"]),
        .executable(name: "ReplayUpdater", targets: ["ReplayUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "Replay",
            path: "Sources/Replay"
        ),
        .executableTarget(
            name: "ReplayUpdater",
            path: "Sources/ReplayUpdater"
        )
    ],
    swiftLanguageVersions: [.v5]
)
