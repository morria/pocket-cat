// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FT891",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FT891Kit", targets: ["FT891Kit"]),
        .library(name: "FT891UI", targets: ["FT891UI"]),
    ],
    dependencies: [
        .package(path: "../pocket-cat"),
    ],
    targets: [
        // Radio semantics: menu catalog, command wrappers, profiles, sim.
        .target(name: "FT891Kit",
                dependencies: [
                    .product(name: "CATBridgeKit", package: "pocket-cat"),
                ]),
        // SwiftUI app surface; the App/ Xcode shell wraps this.
        .target(name: "FT891UI", dependencies: ["FT891Kit"]),
        .testTarget(name: "FT891KitTests", dependencies: ["FT891Kit"]),
    ]
)
