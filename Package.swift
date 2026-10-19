// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenNTFS",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OpenNTFS"),
        .testTarget(name: "OpenNTFSTests", dependencies: ["OpenNTFS"]),
    ]
)
