// Control-plane tests: golden vectors shared with the firmware
// (Resources/ctrlproto.json, byte-compared in CI against
// esp32s3/test/vectors/ctrlproto.json) plus structural codec tests.

import Foundation
import Testing
@testable import CATBridgeCore

// MARK: - Golden vector loading

struct VectorFile: Decodable {
    struct FrameVector: Decodable {
        let name: String
        let op: UInt8
        let payload_hex: String
        let wire_hex: String
    }
    struct StatusVector: Decodable {
        struct Decoded: Decodable {
            let usb_state: UInt8
            let radio_id: UInt8
            let baud: UInt32
            let drops_usb_to_ble: UInt32
            let drops_ble_to_usb: UInt32
            let fw_major: UInt8
            let fw_minor: UInt8
            let reset_reason: UInt8
            let min_free_heap: UInt32
        }
        let name: String
        let wire_hex: String
        let decoded: Decoded
    }
    struct InvalidStatusVector: Decodable {
        let name: String
        let wire_hex: String
        let reason: String
    }
    let frames: [FrameVector]
    let status: [StatusVector]
    let invalid_status: [InvalidStatusVector]
}

func loadVectors() throws -> VectorFile {
    let url = try #require(Bundle.module.url(forResource: "ctrlproto",
                                             withExtension: "json"))
    return try JSONDecoder().decode(VectorFile.self,
                                    from: Data(contentsOf: url))
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

// name → our encoder, mirroring FRAME_ENCODERS in test_catproto.py.
let frameEncoders: [String: @Sendable () throws -> CtrlFrame] = [
    "set_baud_38400": { CtrlCommand.setBaud(38400) },
    "set_baud_4800": { CtrlCommand.setBaud(4800) },
    "get_status": { CtrlCommand.getStatus() },
    "usb_reset": { CtrlCommand.usbReset() },
    "set_line_dtr": { CtrlCommand.setLine(dtr: true, rts: false) },
    "set_line_rts": { CtrlCommand.setLine(dtr: false, rts: true) },
    "set_line_both": { CtrlCommand.setLine(dtr: true, rts: true) },
    "purge_usb_to_ble": { CtrlCommand.purge(usbToBLE: true, bleToUSB: false) },
    "purge_ble_to_usb": { CtrlCommand.purge(usbToBLE: false, bleToUSB: true) },
    "set_failsafe_tx0": { try CtrlCommand.setFailsafe(Data("TX0;".utf8)) },
    "set_failsafe_rx": { try CtrlCommand.setFailsafe(Data("RX;".utf8)) },
    "set_failsafe_disarm": { try CtrlCommand.setFailsafe(Data()) },
]

@Suite struct GoldenVectorTests {
    @Test func frameVectors() throws {
        let vectors = try loadVectors()
        #expect(!vectors.frames.isEmpty)
        for vector in vectors.frames {
            let wire = try #require(Data(hex: vector.wire_hex))
            let payload = try #require(Data(hex: vector.payload_hex))
            // Structural invariants.
            #expect(wire[wire.startIndex] == vector.op, "\(vector.name)")
            #expect(Int(wire[wire.index(after: wire.startIndex)])
                    == payload.count, "\(vector.name)")
            // Decode round-trip.
            var buffer = wire
            let frames = CtrlFrame.decodeStream(&buffer)
            #expect(buffer.isEmpty, "\(vector.name)")
            #expect(frames.count == 1, "\(vector.name)")
            #expect(frames.first?.op == vector.op, "\(vector.name)")
            #expect(frames.first?.payload == payload, "\(vector.name)")
            // Encoder vectors must match byte-for-byte.
            if let encoder = frameEncoders[vector.name] {
                #expect(try encoder().encoded == wire, "\(vector.name)")
            }
        }
    }

    @Test func statusVectors() throws {
        let vectors = try loadVectors()
        for vector in vectors.status {
            let wire = try #require(Data(hex: vector.wire_hex))
            let status = try BridgeStatus(decoding: wire)
            let expected = vector.decoded
            #expect(status.usbState
                    == BridgeUSBState(byte: expected.usb_state),
                    "\(vector.name)")
            #expect(status.radioID == BridgeRadioID(byte: expected.radio_id),
                    "\(vector.name)")
            #expect(status.baud == expected.baud, "\(vector.name)")
            #expect(status.droppedUSBToBLE == expected.drops_usb_to_ble)
            #expect(status.droppedBLEToUSB == expected.drops_ble_to_usb)
            #expect(status.firmwareMajor == expected.fw_major)
            #expect(status.firmwareMinor == expected.fw_minor)
            #expect(status.resetReason == expected.reset_reason)
            #expect(status.minimumFreeHeap == expected.min_free_heap)
        }
    }

    @Test func invalidStatusVectors() throws {
        let vectors = try loadVectors()
        for vector in vectors.invalid_status {
            let wire = try #require(Data(hex: vector.wire_hex))
            #expect(throws: (any Error).self, "\(vector.name)") {
                _ = try BridgeStatus(decoding: wire)
            }
        }
    }

    @Test func everyEncoderHasAVector() throws {
        let names = Set(try loadVectors().frames.map(\.name))
        #expect(Set(frameEncoders.keys).isSubset(of: names))
    }
}

// MARK: - Structural codec tests

@Suite struct CtrlFrameTests {
    @Test func decodeStreamHandlesPartialFrames() {
        let ack = CtrlFrame(op: CtrlOp.ack.rawValue,
                            payload: Data([0x01, 0x00])).encoded
        let overflowFull = CtrlFrame(op: CtrlOp.evtOverflow.rawValue,
                                     payload: Data([0, 1, 0, 0, 0])).encoded
        var buffer = ack + overflowFull.prefix(3)
        var frames = CtrlFrame.decodeStream(&buffer)
        #expect(frames.count == 1)
        #expect(frames[0].op == CtrlOp.ack.rawValue)
        #expect(buffer == overflowFull.prefix(3))

        buffer.append(overflowFull.dropFirst(3))
        frames = CtrlFrame.decodeStream(&buffer)
        #expect(frames.count == 1)
        #expect(frames[0].op == CtrlOp.evtOverflow.rawValue)
        #expect(buffer.isEmpty)
    }

    @Test func decodeStreamEmptyAndHeaderOnly() {
        var empty = Data()
        #expect(CtrlFrame.decodeStream(&empty).isEmpty)
        var headerOnly = Data([0x42])
        #expect(CtrlFrame.decodeStream(&headerOnly).isEmpty)
        #expect(headerOnly == Data([0x42]))
    }

    @Test func replyDecoding() {
        #expect(CtrlReply(frame: CtrlFrame(op: 0x80,
                                           payload: Data([0x01, 0x00])))
                == .ack(forOp: 0x01))
        #expect(CtrlReply(frame: CtrlFrame(op: 0x81,
                                           payload: Data([0x05, 0x02])))
                == .nak(forOp: 0x05, code: .badArgument))
        #expect(CtrlReply(frame: CtrlFrame(op: 0x82,
                                           payload: Data([1, 1])))
                == .usbEvent(state: .enumerated, radio: .ft891))
        let overflow = CtrlReply(
            frame: CtrlFrame(op: 0x83,
                             payload: Data([0x01, 0xB0, 0xA0, 0x02, 0x01])))
        #expect(overflow == .overflow(direction: .bleToUSB,
                                      dropped: 0x0102_A0B0))
    }

    @Test func failsafeSizeLimit() {
        #expect(throws: (any Error).self) {
            _ = try CtrlCommand.setFailsafe(Data(repeating: 0, count: 33))
        }
        #expect(throws: Never.self) {
            _ = try CtrlCommand.setFailsafe(Data(repeating: 0, count: 32))
        }
    }

    @Test func statusToleratesFutureTrailingBytes() throws {
        var wire = Data([1, 1, 1])
        wire.append(UInt32(38400).littleEndianData)
        wire.append(UInt32(0).littleEndianData)
        wire.append(UInt32(0).littleEndianData)
        wire.append(contentsOf: [0, 2, 0])
        wire.append(UInt32(1024).littleEndianData)
        wire.append(contentsOf: [0xAA, 0xBB, 0xCC]) // future minor additions
        let status = try BridgeStatus(decoding: wire)
        #expect(status.firmwareMinor == 2)
        #expect(status.minimumFreeHeap == 1024)
    }

    @Test func unknownRadioIDPreserved() {
        #expect(BridgeRadioID(byte: 42) == .unknown(42))
        #expect(BridgeRadioID(byte: 42).usesRealBaud == false)
    }
}
