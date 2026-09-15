// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-tasking",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "TaskingCore",
            targets: ["TaskingCore"]
        ),
        .library(
            name: "Tasking",
            targets: ["Tasking"]
        )
    ],
    targets: [
        .target(name: "TaskingCore"),
        .target(
            name: "Tasking",
            dependencies: ["TaskingCore"]
        ),
        .target(name: "TaskingTestSupport", path: "Tests/Support"),
        .testTarget(
            name: "TaskingCoreTests",
            dependencies: ["TaskingCore", "TaskingTestSupport"]
        ),
        .testTarget(
            name: "TaskingTests",
            dependencies: ["Tasking", "TaskingTestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
