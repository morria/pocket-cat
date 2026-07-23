// STATUS characteristic payload (protocol.md §3): 22 bytes, little-endian,
// versioned. Decoding tolerates trailing bytes from future firmware minors.

import Foundation

/// USB link state as reported by the bridge.
public enum BridgeUSBState: Sendable, Equatable {
    case waiting
    case enumerated
    case error
    case unknown(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0: self = .waiting
        case 1: self = .enumerated
        case 2: self = .error
        default: self = .unknown(byte)
        }
    }
}

/// Radio identity as detected by the bridge's USB match table.
public enum BridgeRadioID: Sendable, Equatable {
    case none
    case ft891
    case genericCP210x
    case qmxCDC
    case genericFTDI
    case unsupported
    case unknown(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0: self = .none
        case 1: self = .ft891
        case 2: self = .genericCP210x
        case 3: self = .qmxCDC
        case 4: self = .genericFTDI
        case 5: self = .unsupported
        default: self = .unknown(byte)
        }
    }

    /// The bridge told us the transport chip family; true when the radio
    /// needs a real baud rate (CP210x UART bridges, unlike native-USB CDC).
    public var usesRealBaud: Bool {
        switch self {
        case .ft891, .genericCP210x, .genericFTDI: return true
        default: return false
        }
    }
}

/// Decoded STATUS snapshot.
public struct BridgeStatus: Sendable, Equatable {
    public static let formatVersion: UInt8 = 1
    public static let minimumSize = 22

    public let usbState: BridgeUSBState
    public let radioID: BridgeRadioID
    public let baud: UInt32
    public let droppedUSBToBLE: UInt32
    public let droppedBLEToUSB: UInt32
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let resetReason: UInt8
    public let minimumFreeHeap: UInt32

    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.minimumSize else {
            throw CATBridgeError.malformedResponse(
                "STATUS too short: \(bytes.count) bytes")
        }
        guard bytes[0] == Self.formatVersion else {
            throw CATBridgeError.statusVersionUnsupported(bytes[0])
        }
        usbState = BridgeUSBState(byte: bytes[1])
        radioID = BridgeRadioID(byte: bytes[2])
        baud = UInt32(littleEndianBytes: Array(bytes[3...6]))
        droppedUSBToBLE = UInt32(littleEndianBytes: Array(bytes[7...10]))
        droppedBLEToUSB = UInt32(littleEndianBytes: Array(bytes[11...14]))
        firmwareMajor = bytes[15]
        firmwareMinor = bytes[16]
        resetReason = bytes[17]
        minimumFreeHeap = UInt32(littleEndianBytes: Array(bytes[18...21]))
        // Bytes beyond 22 are future minor-version additions: ignored.
    }
}
