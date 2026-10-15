// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CastMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CastMenubar", path: "Sources/CastMenubar")
    ]
)
