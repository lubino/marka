// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marka",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MarkaCore", targets: ["MarkaCore"]),
        .library(name: "MarkaUI", targets: ["MarkaUI"]),
        .executable(name: "Marka", targets: ["Marka"])
    ],
    targets: [
        .target(
            name: "MarkaCore",
            path: "Sources/MarkaCore"
        ),
        .target(
            name: "MarkaUI",
            dependencies: ["MarkaCore"],
            path: "Sources/MarkaApp",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "Marka",
            dependencies: ["MarkaUI"],
            path: "Sources/MarkaLauncher",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "MarkaTests",
            dependencies: ["MarkaCore"],
            path: "Tests/MarkaCoreTests"
        ),
        .executableTarget(
            name: "MarkaUITests",
            dependencies: ["MarkaUI", "MarkaCore"],
            path: "Tests/MarkaUITests",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
