// The BLE layer is deliberately thin; its logic-bearing pieces (UUID
// identity, event mapping) are checked here. Full CB delegate behavior is
// exercised on-device (docs/implementation.md §9.4).

#if canImport(CoreBluetooth)
import CoreBluetooth
import Testing
@testable import CATBridgeBLE

@Suite struct BridgeGATTTests {
    @Test func uuidsMatchProtocolSpec() {
        // Must equal the literals in esp32s3/docs/protocol.md §1 /
        // test/tools/catproto.py.
        #expect(BridgeGATT.serviceUUIDString
                == "8F1D0001-52A4-4E1E-B34B-9D40B71D6E01")
        #expect(BridgeGATT.catRXUUIDString.hasPrefix("8F1D0002"))
        #expect(BridgeGATT.catTXUUIDString.hasPrefix("8F1D0003"))
        #expect(BridgeGATT.ctrlUUIDString.hasPrefix("8F1D0004"))
        #expect(BridgeGATT.statusUUIDString.hasPrefix("8F1D0005"))
        // All five share the 128-bit base.
        for uuid in [BridgeGATT.catRXUUIDString, BridgeGATT.catTXUUIDString,
                     BridgeGATT.ctrlUUIDString, BridgeGATT.statusUUIDString] {
            #expect(uuid.hasSuffix("-52A4-4E1E-B34B-9D40B71D6E01"))
        }
    }

    @Test func cbuuidsParse() {
        #expect(BridgeGATT.service.uuidString
                == BridgeGATT.serviceUUIDString)
        #expect(BridgeGATT.characteristics.count == 4)
    }

    @Test func discoveredBridgeIsValueData() {
        let id = UUID()
        let bridge = DiscoveredBridge(id: id, name: "CATBridge-3F2A",
                                      rssi: -60)
        #expect(bridge.id == id)
        #expect(bridge == DiscoveredBridge(id: id, name: "CATBridge-3F2A",
                                           rssi: -60))
    }
}
#endif
