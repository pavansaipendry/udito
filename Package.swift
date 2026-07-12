// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ears",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Ears",
            path: "Sources/Ears"
        ),
        .testTarget(
            name: "EarsTests",
            dependencies: ["Ears"],
            path: "Tests/EarsTests"
        ),
    ]
)
