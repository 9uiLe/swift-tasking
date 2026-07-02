// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskingPrototype",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "TaskingPrototype", targets: ["TaskingPrototype"])
    ],
    dependencies: [
        .package(name: "swift-tasking", path: "../..")
    ],
    targets: [
        .target(
            name: "TaskingPrototype",
            dependencies: [
                .product(name: "Tasking", package: "swift-tasking")
            ]
        ),
        .testTarget(
            name: "TaskingPrototypeTests",
            dependencies: ["TaskingPrototype"]
        )
    ],
    swiftLanguageModes: [.v6]
)
