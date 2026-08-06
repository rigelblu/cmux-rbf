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
        // cmux-rbf: capped below 9.16.0. Upstream declares `from: "9.0.0"`, an open
        // upper bound. The original cap sat below 9.15.0, because 9.15.0 adds
        // `.fileSystemSynchronizedGroup` and made the switch in
        // XcodeProjectAdapter.swift non-exhaustive; it was lifted per its own
        // release condition once that case arrived, in upstream's own one-line fix
        // that came with the 2026-08 sync (`case let .group(group),
        // let .fileSystemSynchronizedGroup(group)`).
        // The cap itself stays. Any build that resolves freely drifts the lockfile
        // and breaks the next build, so it presents as "it worked yesterday".
        // Three separate commands hit that before the cap existed: `make build`,
        // `make test`, and `make install`.
        // Lift again only together with whatever case the next minor adds.
        // Reject this hunk on upstream sync.
        .package(
            url: "https://github.com/tuist/XcodeProj.git",
            "9.0.0" ..< "9.16.0"
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
