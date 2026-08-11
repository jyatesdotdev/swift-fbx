// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-fbx",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v16), .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftFBX", targets: ["SwiftFBX"]),
        .executable(name: "fbx-dump", targets: ["fbx-dump"]),
    ],
    targets: [
        .target(
            name: "SwiftFBX",
            exclude: [
                "AGENTS.md",
                "Core/AGENTS.md",
                "Document/AGENTS.md",
                "Evaluate/AGENTS.md",
                "Geometry/AGENTS.md",
                "Loader/AGENTS.md",
                "Math/AGENTS.md",
                "Scene/AGENTS.md",
            ]
        ),
        .target(
            name: "FBXDumpCore",
            dependencies: ["SwiftFBX"],
            exclude: ["AGENTS.md"]
        ),
        .executableTarget(
            name: "fbx-dump",
            dependencies: ["SwiftFBX", "FBXDumpCore"]
        ),
        .testTarget(
            name: "SwiftFBXTests",
            dependencies: ["SwiftFBX", "FBXDumpCore"],
            exclude: ["AGENTS.md"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
