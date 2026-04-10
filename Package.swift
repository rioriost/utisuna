// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "utisuna",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "utisuna", targets: ["utisuna"])
    ],
    targets: [
        .executableTarget(
            name: "utisuna",
            path: "Sources/utisuna"
        ),
        .testTarget(
            name: "utisunaTests",
            dependencies: ["utisuna"],
            path: "Tests/utisunaTests"
        )
    ]
)
