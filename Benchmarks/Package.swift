// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskingBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "swift-tasking", path: "..")],
    targets: [
        .executableTarget(
            name: "TaskingBenchmarks",
            dependencies: [
                .product(name: "Tasking", package: "swift-tasking"),
                .product(name: "TaskingCore", package: "swift-tasking")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
