// CTRL TLV codec for the bridge control channel.
// Normative contract: esp32s3/docs/protocol.md §2. Wire-compatible with the
// firmware's ctrl_proto component; golden vectors in
// esp32s3/test/vectors/ctrlproto.json keep the implementations honest.

import Foundation

/// Opcodes for the CTRL characteristic (`protocol.md` §2).
public enum CtrlOp: UInt8, Sendable, CaseIterable {
    case setBaud = 0x01
    case getStatus = 0x02
    case usbReset = 0x03
    case setLine = 0x04
    case purge = 0x05
    case setFailsafe = 0x06
    case ack = 0x80
    case nak = 0x81
    case evtUSB = 0x82
    case evtOverflow = 0x83
}

/// Error codes carried in ACK/NAK payloads.
public struct CtrlErrCode: RawRepresentable, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ok = CtrlErrCode(rawValue: 0x00)
    public static let badLength = CtrlErrCode(rawValue: 0x01)
    public static let badArgument = CtrlErrCode(rawValue: 0x02)
    public static let noUSB = CtrlErrCode(rawValue: 0x03)
    public static let unsupported = CtrlErrCode(rawValue: 0x04)
    public static let busy = CtrlErrCode(rawValue: 0x05)
    public static let unknownOp = CtrlErrCode(rawValue: 0x06)
}

/// One `[opcode][len][payload]` frame.
public struct CtrlFrame: Sendable, Equatable {
    public static let maxPayload = 255
    public static let failsafeMaxLength = 32

    public let op: UInt8
    public let payload: Data

    public init(op: UInt8, payload: Data = Data()) {
        precondition(payload.count <= Self.maxPayload)
        self.op = op
        self.payload = payload
    }

    public var encoded: Data {
        var d = Data(capacity: 2 + payload.count)
        d.append(op)
        d.append(UInt8(payload.count))
        d.append(payload)
        return d
    }

    /// Decodes every complete frame at the front of `buffer`, consuming the
    /// bytes it used and leaving any incomplete tail in place.
    public static func decodeStream(_ buffer: inout Data) -> [CtrlFrame] {
        var frames: [CtrlFrame] = []
        var bytes = [UInt8](buffer)
        var offset = 0
        while bytes.count - offset >= 2 {
            let length = Int(bytes[offset + 1])
            guard bytes.count - offset >= 2 + length else { break }
            let payload = Data(bytes[(offset + 2)..<(offset + 2 + length)])
            frames.append(CtrlFrame(op: bytes[offset], payload: payload))
            offset += 2 + length
        }
        if offset > 0 {
            bytes.removeFirst(offset)
            buffer = Data(bytes)
        }
        return frames
    }
}

/// Builders for the central→peripheral commands.
public enum CtrlCommand {
    public static func setBaud(_ baud: UInt32) -> CtrlFrame {
        CtrlFrame(op: CtrlOp.setBaud.rawValue, payload: baud.littleEndianData)
    }

    public static func getStatus() -> CtrlFrame {
        CtrlFrame(op: CtrlOp.getStatus.rawValue)
    }

    public static func usbReset() -> CtrlFrame {
        CtrlFrame(op: CtrlOp.usbReset.rawValue)
    }

    public static func setLine(dtr: Bool, rts: Bool) -> CtrlFrame {
        let bitmap: UInt8 = (dtr ? 0x01 : 0x00) | (rts ? 0x02 : 0x00)
        return CtrlFrame(op: CtrlOp.setLine.rawValue, payload: Data([bitmap]))
    }

    public static func purge(usbToBLE: Bool, bleToUSB: Bool) -> CtrlFrame {
        let mask: UInt8 = (usbToBLE ? 0x01 : 0x00) | (bleToUSB ? 0x02 : 0x00)
        return CtrlFrame(op: CtrlOp.purge.rawValue, payload: Data([mask]))
    }

    /// Empty data disarms. Throws for payloads over the 32-byte firmware limit.
    public static func setFailsafe(_ data: Data) throws -> CtrlFrame {
        guard data.count <= CtrlFrame.failsafeMaxLength else {
            throw CATBridgeError.invalidArgument(
                "failsafe limited to \(CtrlFrame.failsafeMaxLength) bytes")
        }
        return CtrlFrame(op: CtrlOp.setFailsafe.rawValue, payload: data)
    }
}

/// Decoded peripheral→central reply/event.
public enum CtrlReply: Sendable, Equatable {
    case ack(forOp: UInt8)
    case nak(forOp: UInt8, code: CtrlErrCode)
    case statusAnswer(Data)
    case usbEvent(state: BridgeUSBState, radio: BridgeRadioID)
    case overflow(direction: OverflowDirection, dropped: UInt32)
    case unknown(CtrlFrame)

    public init(frame: CtrlFrame) {
        switch frame.op {
        case CtrlOp.ack.rawValue where frame.payload.count >= 2:
            self = .ack(forOp: frame.payload[frame.payload.startIndex])
        case CtrlOp.nak.rawValue where frame.payload.count >= 2:
            let bytes = [UInt8](frame.payload)
            self = .nak(forOp: bytes[0], code: CtrlErrCode(rawValue: bytes[1]))
        case CtrlOp.getStatus.rawValue:
            self = .statusAnswer(frame.payload)
        case CtrlOp.evtUSB.rawValue where frame.payload.count >= 2:
            let bytes = [UInt8](frame.payload)
            self = .usbEvent(state: BridgeUSBState(byte: bytes[0]),
                             radio: BridgeRadioID(byte: bytes[1]))
        case CtrlOp.evtOverflow.rawValue where frame.payload.count >= 5:
            let bytes = [UInt8](frame.payload)
            let dropped = UInt32(littleEndianBytes: Array(bytes[1...4]))
            self = .overflow(
                direction: bytes[0] == 0 ? .usbToBLE : .bleToUSB,
                dropped: dropped)
        default:
            self = .unknown(frame)
        }
    }
}

public enum OverflowDirection: Sendable, Equatable {
    case usbToBLE
    case bleToUSB
}

// MARK: - Little-endian helpers

extension UInt32 {
    var littleEndianData: Data {
        Data([UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF),
              UInt8((self >> 16) & 0xFF), UInt8((self >> 24) & 0xFF)])
    }

    init(littleEndianBytes b: [UInt8]) {
        self = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16)
            | (UInt32(b[3]) << 24)
    }
}
