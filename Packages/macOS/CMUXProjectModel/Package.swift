// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXProjectModel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXProjectModel",
            targets: ["CMUXProjectModel"]
        ),
        .executable(
            name: "cmux-project-dump",
            targets: ["CMUXProjectDump"]
        ),
    ],
    // cmux-rbf: the fork capped XcodeProj below 9.16.0 here (#cm-17) because a free
    // resolve drifted the lockfile and broke the next build. Upstream dropped XcodeProj
    // and PathKit entirely (fcad43f225, reads Xcode projects with Foundation), so the
    // package has no dependencies and the cap retired with the 2026-11 sync (#cm-142.1).
    // If a dependency returns here, cap it again. Reject an uncapped one on upstream sync.
    targets: [
        .target(
            name: "CMUXProjectModel"
        ),
        .executableTarget(
            name: "CMUXProjectDump",
            dependencies: ["CMUXProjectModel"]
        ),
        .testTarget(
            name: "CMUXProjectModelTests",
            dependencies: ["CMUXProjectModel"]
        ),
    ]
)
