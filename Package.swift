// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marka",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarkaCore", targets: ["MarkaCore"]),
        .executable(name: "Marka", targets: ["MarkaApp"])
    ],
    targets: [
        .target(
            name: "MarkaCore",
            path: "Sources/MarkaCore"
        ),
        .executableTarget(
            name: "MarkaApp",
            dependencies: ["MarkaCore"],
            path: "Sources/MarkaApp",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "MarkaTests",
            dependencies: ["MarkaCore"],
            path: "Tests/MarkaCoreTests"
        )
    ]
)
