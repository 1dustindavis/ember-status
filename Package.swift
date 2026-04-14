// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmberStatus",
    platforms: [
        .iOS("17.0"),
        .macOS("14.0")
    ],
    products: [
        .library(name: "EmberCore", targets: ["EmberCore"])
    ],
    targets: [
        .target(name: "EmberCore"),
        .testTarget(name: "EmberCoreTests", dependencies: ["EmberCore"])
    ]
)
