// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MoobilityCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MoobilityCore", targets: ["MoobilityCore"])],
    targets: [
        .target(name: "MoobilityCore"),
        .testTarget(name: "MoobilityCoreTests", dependencies: ["MoobilityCore"]),
    ]
)
