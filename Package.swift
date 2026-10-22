// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiveIsland",
    platforms: [.macOS(.v14)],
    targets: [
        // Parsers and decisions with no UI or system access, so they can be tested directly.
        .target(name: "LiveIslandCore", path: "Sources/LiveIslandCore"),
        .executableTarget(name: "LiveIsland", dependencies: ["LiveIslandCore"], path: "Sources/LiveIsland"),
        .testTarget(name: "LiveIslandCoreTests", dependencies: ["LiveIslandCore"], path: "Tests/LiveIslandCoreTests"),
    ]
)
