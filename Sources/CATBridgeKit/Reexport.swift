// Umbrella module: `import CATBridgeKit` gives apps the whole library.
// CATBridgeCore stays importable alone for BLE-free consumers (tests,
// server-side tools, custom transports).

@_exported import CATBridgeCore
#if canImport(CoreBluetooth)
@_exported import CATBridgeBLE
#endif
