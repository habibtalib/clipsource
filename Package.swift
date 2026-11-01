// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClipSource",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipSource", targets: ["ClipSourceApp"]),
        .executable(name: "clipsrc", targets: ["clipsrc"]),
        .executable(name: "clipsource-mcp", targets: ["clipsource-mcp"]),
        .library(name: "ClipCore", targets: ["ClipCore"]),
    ],
    targets: [
        .target(name: "ClipCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClipSourceApp", dependencies: ["ClipCore"]),
        .executableTarget(name: "clipsrc", dependencies: ["ClipCore"]),
        .executableTarget(name: "clipsource-mcp", dependencies: ["ClipCore"]),
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"]),
    ]
)
