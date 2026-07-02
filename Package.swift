// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskRunner",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "Tasking",
            targets: ["Tasking"]
        )
    ],
    targets: [
        .target(name: "Tasking"),
        .testTarget(
            name: "TaskingTests",
            dependencies: ["Tasking"]
        )
    ],
    swiftLanguageModes: [.v6]
)
