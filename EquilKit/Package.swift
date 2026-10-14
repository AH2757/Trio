// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EquilKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "EquilKit", targets: ["EquilKit"])
    ],
    targets: [
        .target(
            name: "EquilKit",
            path: "Sources/EquilKit"
        ),
        .testTarget(
            name: "EquilKitTests",
            dependencies: ["EquilKit"],
            path: "Tests/EquilKitTests"
        )
    ]
)