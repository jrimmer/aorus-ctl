// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "aorus-ctl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AorusCore", targets: ["AorusCore"]),
        .executable(name: "aorusctl", targets: ["aorusctl"]),
    ],
    targets: [
        .target(name: "AorusCore"),
        .executableTarget(
            name: "aorusctl",
            dependencies: ["AorusCore"]
        ),
        .testTarget(
            name: "AorusCoreTests",
            dependencies: ["AorusCore"]
        ),
    ]
)
