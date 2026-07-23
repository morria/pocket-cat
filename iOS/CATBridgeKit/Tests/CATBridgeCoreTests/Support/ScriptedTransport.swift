// Test transport implementing BridgeTransport against a radio personality,
// emulating the bridge firmware's observable behavior: CTRL ACK/NAK rules,
// baud gating for UART-bridge radios, failsafe-on-disconnect, STATUS reads.

@testable import CATBridgeCore
import Foundation

enum JournalEntry: Equatable, Sendable {
    case cat(String)
    case ctrl(op: UInt8, payload: Data)
}

actor ScriptedTransport: BridgeTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private let radio: RadioPersonality
    private let radioID: BridgeRadioID

    private(set) var journal: [JournalEntry] = []
    private(set) var connected = false
    private var appliedBaud: UInt32
    private var failsafe = Data()
    /// Deliver radio→central bytes in chunks of this size (1 = byte drip).
    var responseChunkSize: Int = 64
    /// Fail the next N connect() calls.
    var failConnects = 0

    init(radio: RadioPersonality, radioID: BridgeRadioID,
         initialBaud: UInt32 = 4800) {
        self.radio = radio
        self.radioID = radioID
        self.appliedBaud = initialBaud
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    // MARK: - BridgeTransport

    func connect() async throws {
        if failConnects > 0 {
            failConnects -= 1
            throw CATBridgeError.connectionFailed("scripted failure")
        }
        connected = true
        continuation.yield(.connected)
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        applyFirmwareFailsafe()
    }

    func writeCAT(_ data: Data) async throws {
        guard connected else { throw CATBridgeError.connectionLost }
        journal.append(.cat(String(decoding: data, as: UTF8.self)))
        // Baud gating: mismatched line coding = the radio hears noise.
        if let menuBaud = radio.menuBaud, menuBaud != appliedBaud { return }
        let reply = radio.feed(data)
        deliverCAT(reply)
    }

    func writeCtrl(_ frame: Data) async throws {
        guard connected else { throw CATBridgeError.connectionLost }
        var buffer = frame
        let frames = CtrlFrame.decodeStream(&buffer)
        for f in frames {
            journal.append(.ctrl(op: f.op, payload: f.payload))
            handleCtrl(f)
        }
    }

    func readStatus() async throws -> Data {
        guard connected else { throw CATBridgeError.connectionLost }
        return statusData()
    }

    // MARK: - Test controls

    /// Simulate the BLE link dying (peer out of range / app killed). The
    /// firmware then emits the armed failsafe to the radio (§5.5).
    func dropLink() {
        guard connected else { return }
        connected = false
        applyFirmwareFailsafe()
        continuation.yield(.disconnected(reason: "scripted drop"))
    }

    /// Inject unsolicited radio→central bytes (Auto-Information style).
    func injectCAT(_ text: String) {
        deliverCAT(Data(text.utf8))
    }

    /// Inject a CTRL event frame (EVT_USB / EVT_OVERFLOW).
    func injectCtrl(_ frame: CtrlFrame) {
        continuation.yield(.ctrlFrame(frame.encoded))
    }

    func setResponseChunkSize(_ size: Int) { responseChunkSize = size }
    func setFailConnects(_ count: Int) { failConnects = count }
    func isTransmitting() -> Bool { radio.transmitting }
    func setMuted(_ muted: Bool) { radio.muted = muted }
    func setStallAfter(_ count: Int?) { radio.stallAfter = count }
    func armedFailsafe() -> Data { failsafe }

    /// Index in the journal of the first entry matching `predicate`.
    func journalIndex(
        where predicate: @Sendable (JournalEntry) -> Bool) -> Int? {
        journal.firstIndex(where: predicate)
    }

    // MARK: - Firmware emulation

    private func applyFirmwareFailsafe() {
        guard !failsafe.isEmpty else { return }
        _ = radio.feed(failsafe) // radio reacts; replies go nowhere
        failsafe = Data()        // one-shot, like the firmware
    }

    private func deliverCAT(_ data: Data) {
        guard !data.isEmpty, connected else { return }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let end = min(offset + max(1, responseChunkSize), bytes.count)
            continuation.yield(.catData(Data(bytes[offset..<end])))
            offset = end
        }
    }

    private func handleCtrl(_ frame: CtrlFrame) {
        func reply(_ f: CtrlFrame) { continuation.yield(.ctrlFrame(f.encoded)) }
        func ack() {
            reply(CtrlFrame(op: CtrlOp.ack.rawValue,
                            payload: Data([frame.op, 0x00])))
        }
        switch frame.op {
        case CtrlOp.setBaud.rawValue:
            if frame.payload.count == 4 {
                appliedBaud = UInt32(
                    littleEndianBytes: [UInt8](frame.payload))
                ack()
            } else {
                reply(CtrlFrame(op: CtrlOp.nak.rawValue,
                                payload: Data([frame.op, 0x01])))
            }
        case CtrlOp.getStatus.rawValue:
            reply(CtrlFrame(op: CtrlOp.getStatus.rawValue,
                            payload: statusData()))
        case CtrlOp.setFailsafe.rawValue:
            failsafe = frame.payload
            ack()
        case CtrlOp.usbReset.rawValue, CtrlOp.setLine.rawValue,
             CtrlOp.purge.rawValue:
            ack()
        default:
            reply(CtrlFrame(op: CtrlOp.nak.rawValue,
                            payload: Data([frame.op, 0x06])))
        }
    }

    private func statusData() -> Data {
        var d = Data()
        d.append(1) // format version
        d.append(1) // usb enumerated
        d.append(radioIDByte)
        d.append(appliedBaud.littleEndianData)
        d.append(UInt32(0).littleEndianData) // drops u2b
        d.append(UInt32(0).littleEndianData) // drops b2u
        d.append(contentsOf: [0, 1, 0])      // fw 0.1, reset reason
        d.append(UInt32(100_000).littleEndianData)
        return d
    }

    private var radioIDByte: UInt8 {
        switch radioID {
        case .none: 0
        case .ft891: 1
        case .genericCP210x: 2
        case .qmxCDC: 3
        case .genericFTDI: 4
        case .unsupported: 5
        case .unknown(let raw): raw
        }
    }
}
