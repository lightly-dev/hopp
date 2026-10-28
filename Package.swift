// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hopp",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Hopp", targets: ["Hopp"])],
    targets: [
        .target(name: "HoppCore"),
        .executableTarget(
            name: "Hopp",
            dependencies: ["HoppCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "HoppCoreTests", dependencies: ["HoppCore"])
    ]
)
