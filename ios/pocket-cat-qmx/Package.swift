// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QMX",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "QMXKit", targets: ["QMXKit"]),
        .library(name: "QMXUI", targets: ["QMXUI"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        // Radio semantics: menu-manager client, profiles, sim, controller.
        .target(
            name: "QMXKit",
            dependencies: [
                .product(name: "CATBridgeKit", package: "pocket-cat"),
            ]),
        // SwiftUI surface; the app shell wraps this.
        .target(name: "QMXUI", dependencies: ["QMXKit"]),
        .testTarget(name: "QMXKitTests", dependencies: ["QMXKit"]),
    ]
)
