// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skylight",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
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
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/Skylight",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SkylightCoreTests",
            dependencies: ["SkylightCore", "SkylightDaemonCore"],
            path: "Tests/SkylightCoreTests"
        ),
    ]
)
