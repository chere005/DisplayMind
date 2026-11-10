// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplayMind",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DisplayMind", targets: ["DisplayMind"])],
    targets: [
        .target(name: "DisplayMindCore"),
        .executableTarget(name: "DisplayMind", dependencies: ["DisplayMindCore"]),
        .testTarget(name: "DisplayMindCoreTests", dependencies: ["DisplayMindCore", "DisplayMind"])
    ]
)
