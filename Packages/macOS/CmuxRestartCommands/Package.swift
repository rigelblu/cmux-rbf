// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRestartCommands",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRestartCommands",
            targets: ["CmuxRestartCommands"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxRestartCommands",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRestartCommandsTests",
            dependencies: ["CmuxRestartCommands"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
