// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CATBridgeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CATBridgeKit", targets: ["CATBridgeKit"]),
    ],
    targets: [
        // Umbrella: apps `import CATBridgeKit`.
        .target(name: "CATBridgeKit",
                dependencies: ["CATBridgeCore", "CATBridgeBLE"]),
        // Pure logic: control plane, CAT dialects, session actor.
        // Must never import CoreBluetooth (docs/implementation.md §3).
        .target(name: "CATBridgeCore"),
        // Thin CoreBluetooth adapter; compiles to nothing on platforms
        // without CoreBluetooth (all sources are canImport-guarded).
        .target(name: "CATBridgeBLE", dependencies: ["CATBridgeCore"]),
        .testTarget(
            name: "CATBridgeCoreTests",
            dependencies: ["CATBridgeCore"],
            resources: [.copy("Resources/ctrlproto.json")]
        ),
        .testTarget(name: "CATBridgeBLETests", dependencies: ["CATBridgeBLE"]),
    ]
)
