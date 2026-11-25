// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loffo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/LoffoKit")],
    targets: [
        .executableTarget(
            name: "Loffo", dependencies: [.product(name: "LoffoKit", package: "LoffoKit")], path: "Sources")
    ]
)
