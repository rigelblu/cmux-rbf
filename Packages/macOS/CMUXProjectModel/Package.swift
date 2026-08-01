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
    dependencies: [
        // cmux-rbf: capped below 9.15.0. Upstream declares `from: "9.0.0"`, an open
        // upper bound — and XcodeProj 9.15.0 adds `.fileSystemSynchronizedGroup`,
        // which makes the switch in XcodeProjectAdapter.swift:706 non-exhaustive.
        // Any build that resolves freely drifts the lockfile and breaks the next
        // build, so it presents as "it worked yesterday". Three separate commands
        // hit this before the cap: `make build`, `make test`, and `make install`.
        // Lift the cap only together with a `.fileSystemSynchronizedGroup` case.
        // Reject this hunk on upstream sync.
        .package(
            url: "https://github.com/tuist/XcodeProj.git",
            "9.0.0" ..< "9.15.0"
        ),
    ],
    targets: [
        .target(
            name: "CMUXProjectModel",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
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
