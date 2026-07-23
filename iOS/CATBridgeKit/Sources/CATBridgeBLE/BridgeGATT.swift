// GATT identity of the bridge (esp32s3/docs/protocol.md §1). The UUID
// strings are the same literals as test/tools/catproto.py and ble_link.c.

#if canImport(CoreBluetooth)
import CoreBluetooth

public enum BridgeGATT {
    public static let serviceUUIDString = "8F1D0001-52A4-4E1E-B34B-9D40B71D6E01"
    public static let catRXUUIDString = "8F1D0002-52A4-4E1E-B34B-9D40B71D6E01"
    public static let catTXUUIDString = "8F1D0003-52A4-4E1E-B34B-9D40B71D6E01"
    public static let ctrlUUIDString = "8F1D0004-52A4-4E1E-B34B-9D40B71D6E01"
    public static let statusUUIDString = "8F1D0005-52A4-4E1E-B34B-9D40B71D6E01"

    // Computed to avoid global storage of non-Sendable CBUUID instances.
    static var service: CBUUID { CBUUID(string: serviceUUIDString) }
    static var catRX: CBUUID { CBUUID(string: catRXUUIDString) }
    static var catTX: CBUUID { CBUUID(string: catTXUUIDString) }
    static var ctrl: CBUUID { CBUUID(string: ctrlUUIDString) }
    static var status: CBUUID { CBUUID(string: statusUUIDString) }
    static var characteristics: [CBUUID] { [catRX, catTX, ctrl, status] }
}

/// A bridge seen while scanning. Wraps only value data — no CB types in the
/// public API (docs/implementation.md §7).
public struct DiscoveredBridge: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
}
#endif
