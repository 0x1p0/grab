// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Grab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Grab",
            path: "Sources/Grab"
        ),
        .testTarget(
            name: "GrabTests",
            dependencies: ["Grab"],
            path: "Tests/GrabTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
