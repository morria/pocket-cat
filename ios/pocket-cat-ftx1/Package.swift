// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FTX1",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FTX1Kit", targets: ["FTX1Kit"]),
        .library(name: "FTX1UI", targets: ["FTX1UI"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        // Radio semantics: command wrappers, passband, memories, sim.
        .target(name: "FTX1Kit",
                dependencies: [
                    .product(name: "CATBridgeKit", package: "pocket-cat"),
                ]),
        // SwiftUI app surface; the App/ Xcode shell wraps this.
        .target(name: "FTX1UI", dependencies: ["FTX1Kit"]),
        .testTarget(name: "FTX1KitTests", dependencies: ["FTX1Kit"]),
    ]
)
