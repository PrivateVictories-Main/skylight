// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skylight",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Vendor/GhosttyKit"),
    ],
    targets: [
        .target(
            name: "SkylightCore",
            path: "Sources/SkylightCore"
        ),
        .target(
            name: "SkylightDaemonCore",
            path: "Sources/SkylightDaemonCore"
        ),
        .executableTarget(
            name: "skylightd",
            dependencies: ["SkylightDaemonCore"],
            path: "Sources/skylightd"
        ),
        .executableTarget(
            name: "Skylight",
            dependencies: [
                "SkylightCore",
                "SkylightDaemonCore",
                .product(name: "GhosttyTerminal", package: "GhosttyKit"),
                // 485 bundled themes, already on disk in the engine package:
                // a real choice on day one with nothing to parse. Depended on
                // by the APP, never by SkylightCore — Core stays engine-free
                // so its theme logic can be tested without a surface.
                .product(name: "GhosttyTheme", package: "GhosttyKit"),
            ],
            path: "Sources/Skylight",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SkylightCoreTests",
            dependencies: ["SkylightCore", "SkylightDaemonCore"],
            path: "Tests/SkylightCoreTests"
        ),
        .testTarget(
            name: "SkylightAppTests",
            dependencies: ["Skylight"],
            path: "Tests/SkylightAppTests"
        ),
    ]
)
