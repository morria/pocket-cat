// A BridgeTransport that impersonates the Pocket Cat bridge with an FTX-1
// attached — the whole app runs against it with no hardware (tests,
// previews, demo mode). Wire behavior mirrors pocket-cat's radio_sim
// FTX-1 personality, extended with the full EX menu table.

import CATBridgeCore
import Foundation

public actor FTX1SimTransport: BridgeTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation:
        AsyncStream<TransportEvent>.Continuation

    private var rig: FTX1SimRig
    private var linkBaud: UInt32 = 4800
    private var connected = false
    /// Complete CAT commands received, for ordering assertions in tests.
    public private(set) var journalEntries: [String] = []
    private var journalBuffer = ""

    public init(rig: FTX1SimRig = FTX1SimRig()) {
        (events, continuation) = AsyncStream.makeStream(
            of: TransportEvent.self)
        self.rig = rig
    }

    // MARK: - BridgeTransport

    public func connect() async throws {
        connected = true
        continuation.yield(.connected)
    }

    public func disconnect() async {
        connected = false
    }

    public func writeCAT(_ data: Data) async throws {
        guard connected else { throw CATBridgeError.connectionLost }
        journalBuffer += String(decoding: data, as: UTF8.self)
        while let end = journalBuffer.firstIndex(of: ";") {
            journalEntries.append(String(journalBuffer[...end]))
            journalBuffer.removeSubrange(...end)
        }
        // Wrong UART baud ↔ radio CAT RATE: silence (the probe walks on).
        guard linkBaud == rig.catRate else { return }
        let replies = rig.feed(data)
        for reply in replies {
            continuation.yield(.catData(Data(reply.utf8)))
        }
    }

    public func writeCtrl(_ frame: Data) async throws {
        guard connected else { throw CATBridgeError.connectionLost }
        var buffer = frame
        for decoded in CtrlFrame.decodeStream(&buffer) {
            handleCtrl(decoded)
        }
    }

    public func readStatus() async throws -> Data {
        guard connected else { throw CATBridgeError.connectionLost }
        return statusBytes()
    }

    // MARK: - Test / demo hooks

    /// Snapshot of the simulated rig for assertions.
    public var rigState: FTX1SimRig { rig }

    public func setRig(_ transform: @Sendable (inout FTX1SimRig) -> Void) {
        transform(&rig)
    }

    /// Simulate the operator turning the dial (emits AI push when enabled).
    public func turnDial(to hz: UInt64) {
        rig.vfoA = hz
        if rig.autoInformation {
            continuation.yield(.catData(Data(rig.ifAnswer().utf8)))
        }
    }

    public func dropLink() {
        connected = false
        continuation.yield(.disconnected(reason: "simulated"))
    }

    // MARK: - CTRL plane

    private func handleCtrl(_ frame: CtrlFrame) {
        func ack(_ op: UInt8) {
            emit(CtrlFrame(op: CtrlOp.ack.rawValue,
                           payload: Data([op, CtrlErrCode.ok.rawValue])))
        }
        switch frame.op {
        case CtrlOp.setBaud.rawValue where frame.payload.count >= 4:
            let b = [UInt8](frame.payload)
            linkBaud = UInt32(b[0]) | (UInt32(b[1]) << 8)
                | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            ack(frame.op)
        case CtrlOp.getStatus.rawValue:
            emit(CtrlFrame(op: CtrlOp.getStatus.rawValue,
                           payload: statusBytes()))
        case CtrlOp.setFailsafe.rawValue, CtrlOp.setLine.rawValue,
             CtrlOp.purge.rawValue, CtrlOp.usbReset.rawValue:
            ack(frame.op)
        default:
            emit(CtrlFrame(op: CtrlOp.nak.rawValue,
                           payload: Data([frame.op,
                                          CtrlErrCode.unknownOp.rawValue])))
        }
    }

    private func emit(_ frame: CtrlFrame) {
        continuation.yield(.ctrlFrame(frame.encoded))
    }

    private func statusBytes() -> Data {
        func le(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
             UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        }
        var d = Data()
        d.append(BridgeStatus.formatVersion)
        d.append(1) // usb enumerated
        d.append(1) // radio id: ftx1
        d.append(contentsOf: le(linkBaud))
        d.append(contentsOf: le(0)) // dropped usb→ble
        d.append(contentsOf: le(0)) // dropped ble→usb
        d.append(contentsOf: [1, 0, 0]) // fw 1.0, reset reason
        d.append(contentsOf: le(180_000)) // min free heap
        return d
    }
}

/// The simulated radio itself: pure state + command→reply logic, kept as a
/// value type so tests can snapshot and mutate it freely.
public struct FTX1SimRig: Sendable {
    // Operating state
    public var vfoA: UInt64 = 14_074_000
    public var vfoB: UInt64 = 7_074_000
    public var modeCode: Character = "2" // USB
    public var txState: Character = "0"  // 0 rx / 1 cat-tx / 2 radio-tx
    public var power = 100
    public var sMeter = 45
    public var tuner: TunerState = .off
    public var split = 0
    public var clarifierOn = false
    public var clarifierOffset = 0
    public var autoInformation = false
    public var frontPanelMenuActive = false
    /// The radio's menu 05-06 CAT RATE as a baud value; the transport goes
    /// silent when the link baud differs (drives the probe walk in tests).
    public var catRate: UInt32 = 38400

    /// Front-panel settings, keyed by wire prefix (AG0, KS, …).
    public var settings: [String: Int] = [
        "AG0": 30, "RG0": 255, "SQ0": 0, "MG": 50, "KS": 20, "BI": 0,
        "NB0": 0, "NR0": 0, "PA0": 1, "RA0": 0, "NA0": 0, "SH0": 15,
    ]

    /// EX menu store: exNumber → raw digit string.
    ///
    /// Generic on purpose. The FT-891 app ships a catalog of its 159 menu
    /// items; the FTX-1's numbering is different and this repo has no
    /// verified catalog for it, so the simulator accepts any four-digit
    /// item and remembers what was written rather than pretending to know
    /// the radio's menu.
    public var menu: [String: String] = [
        "0506": "3",   // CAT rate, consistent with catRate below
    ]

    /// CW keyer memories (KM), 1–5.
    public var keyerMemories: [Int: String] = [:]

    // Passband chain (docs/passband.md; formats per yaesu-cat-ftx1.md
    // "Passband commands"). IS/SH/BP/CO reject in AM/FM like the real rig
    // is assumed to (bench item) — the tests pin that behaviour.
    public var shiftHz = 0
    public var notchOn = false
    public var notchTens = 100      // BP01 units: 10 Hz steps
    public var contourOn = false
    public var contourHz = 800
    public var autoNotchOn = false

    var pending = ""
    var tuneReadsRemaining = 0

    public init() {}

    static let settingDigits: [String: Int] = [
        "AG0": 3, "RG0": 3, "SQ0": 3, "MG": 3, "KS": 3, "BI": 1,
        "NB0": 1, "NR0": 1, "PA0": 1, "RA0": 1, "NA0": 1, "SH0": 2,
    ]

    static let bandStarts: [String: UInt64] = [
        "00": 1_840_000, "01": 3_573_000, "03": 7_074_000, "04": 10_136_000,
        "05": 14_074_000, "06": 18_100_000, "07": 21_074_000,
        "08": 24_915_000, "09": 28_074_000, "10": 50_313_000,
        "11": 5_000_000, "12": 1_000_000,
    ]

    /// Accumulate bytes, split on `;`, answer each complete command.
    public mutating func feed(_ data: Data) -> [String] {
        pending += String(decoding: data, as: UTF8.self)
        var replies: [String] = []
        while let end = pending.firstIndex(of: ";") {
            let command = String(pending[...end])
            pending.removeSubrange(...end)
            if let reply = respond(to: command) {
                replies.append(reply)
            }
        }
        return replies
    }

    func ifAnswer() -> String {
        // Same shape as pocket-cat's simulator (parser-compatible; real-rig
        // offsets carry the documented bring-up caveat).
        let freq = String(format: "%09d", vfoA)
        let clar = String(format: "%@%04d", clarifierOffset < 0 ? "-" : "+",
                          abs(clarifierOffset))
        let rxClar = clarifierOn ? "1" : "0"
        return "IF001\(freq)\(clar)\(rxClar)0\(modeCode)000000;"
    }

    var modeIsAMorFM: Bool { "45BD".contains(modeCode) }

    /// IS/SH/BP/CO handling; returns nil when the command isn't passband.
    private mutating func respondPassband(body: String) -> String?? {
        // Reads (and writes, below) reject in AM/FM like the real radio is
        // assumed to; BC is the exception and works everywhere.
        if modeIsAMorFM,
           ["IS0", "SH0", "BP00", "BP01", "CO00", "CO01"].contains(body) {
            return "?;"
        }
        switch body {
        case "IS0":
            return "IS0\(shiftHz == 0 ? 0 : 1)"
                + String(format: "%+05d;", shiftHz)
        case "SH0":
            return String(format: "SH01%02d;", settings["SH0"] ?? 0)
        case "BP00":
            return "BP00\(notchOn ? "001" : "000");"
        case "BP01":
            return String(format: "BP01%03d;", notchTens)
        case "CO00":
            return "CO00\(contourOn ? "0001" : "0000");"
        case "CO01":
            return String(format: "CO01%04d;", contourHz)
        case "BC0":
            return "BC0\(autoNotchOn ? 1 : 0);"
        default:
            break
        }

        // Sets. BC works in every mode; the rest reject in AM/FM.
        if body.hasPrefix("BC0"), body.count == 4 {
            autoNotchOn = body.last != "0"
            return String?.none
        }
        guard !modeIsAMorFM || !(body.hasPrefix("IS0") || body.hasPrefix("SH0")
            || body.hasPrefix("BP0") || body.hasPrefix("CO0")) else {
            if body.hasPrefix("IS0") || body.hasPrefix("SH0")
                || body.hasPrefix("BP0") || body.hasPrefix("CO0") {
                return "?;"
            }
            return nil
        }
        if body.hasPrefix("IS0"), body.count == 9,
           let hz = Int(body.dropFirst(4)) {
            let on = body.dropFirst(3).first
            guard abs(hz) <= 1200, on == "0" || on == "1" else { return "?;" }
            shiftHz = on == "0" ? 0 : hz
            return String?.none
        }
        if body.hasPrefix("SH01"), body.count == 6,
           let index = Int(body.dropFirst(4)) {
            let family = "12".contains(modeCode)
                ? PassbandTables.ssbFamily : PassbandTables.cwFamily
            guard family.indices.contains(index) else { return "?;" }
            settings["SH0"] = index
            return String?.none
        }
        if body.hasPrefix("BP00"), body.count == 7,
           let value = Int(body.dropFirst(4)) {
            guard value == 0 || value == 1 else { return "?;" }
            notchOn = value == 1
            return String?.none
        }
        if body.hasPrefix("BP01"), body.count == 7,
           let tens = Int(body.dropFirst(4)) {
            guard (1...320).contains(tens) else { return "?;" }
            notchTens = tens
            return String?.none
        }
        if body.hasPrefix("CO00"), body.count == 8,
           let value = Int(body.dropFirst(4)) {
            guard value == 0 || value == 1 else { return "?;" }
            contourOn = value == 1
            return String?.none
        }
        if body.hasPrefix("CO01"), body.count == 8,
           let hz = Int(body.dropFirst(4)) {
            guard (10...3200).contains(hz) else { return "?;" }
            contourHz = hz
            return String?.none
        }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func respond(to cmd: String) -> String? {
        let trimmed = String(cmd.dropLast())
        if let handled = respondPassband(body: trimmed) {
            return handled
        }
        switch cmd {
        case "ID;": return "ID0650;"
        case "IF;": return ifAnswer()
        case "FA;": return String(format: "FA%09d;", vfoA)
        case "FB;": return String(format: "FB%09d;", vfoB)
        case "MD0;": return "MD0\(modeCode);"
        case "TX;": return "TX\(txState);"
        case "TX0;": txState = "0"; return nil
        case "TX1;": txState = "1"; return nil
        case "SM0;": return String(format: "SM0%03d;", sMeter)
        case "PC;": return String(format: "PC%03d;", power)
        case "AI0;": autoInformation = false; return nil
        case "AI1;": autoInformation = true; return nil
        case "AB;": vfoB = vfoA; return nil
        case "BA;": vfoA = vfoB; return nil
        case "SV;": swap(&vfoA, &vfoB); return nil
        case "ST;": return "ST\(split);"
        case "CF0;": return "CF0\(clarifierOn ? 1 : 0)0;"
        case "RC;": clarifierOffset = 0; return nil
        case "RS;": return "RS\(frontPanelMenuActive ? 1 : 0);"
        case "BY;": return "BY00;"
        case "AC;":
            if tuner == .tuning {
                tuneReadsRemaining -= 1
                if tuneReadsRemaining <= 0 { tuner = .on; txState = "0" }
                return "AC002;"
            }
            return "AC00\(tuner.rawValue);"
        default:
            return respondPrefixed(to: cmd)
        }
    }

    private mutating func respondPrefixed(to cmd: String) -> String? {
        let body = String(cmd.dropLast()) // strip ;
        if body.hasPrefix("FA"), body.count == 11,
           let hz = UInt64(body.dropFirst(2)) {
            vfoA = hz
            return nil
        }
        if body.hasPrefix("FB"), body.count == 11,
           let hz = UInt64(body.dropFirst(2)) {
            vfoB = hz
            return nil
        }
        if body.hasPrefix("MD0"), body.count == 4 {
            modeCode = body.last!
            return nil
        }
        if body.hasPrefix("PC"), body.count == 5,
           let watts = Int(body.dropFirst(2)), (5...100).contains(watts) {
            power = watts
            return nil
        }
        if body.hasPrefix("BS"), body.count == 4,
           let start = Self.bandStarts[String(body.dropFirst(2))] {
            vfoA = start
            return nil
        }
        if body.hasPrefix("ST"), body.count == 3,
           let s = body.last?.wholeNumberValue, (0...2).contains(s) {
            split = s
            return nil
        }
        if body.hasPrefix("CF0"), body.count == 5 {
            clarifierOn = body[body.index(body.startIndex, offsetBy: 3)] != "0"
            return nil
        }
        if body.hasPrefix("RU") || body.hasPrefix("RD"), body.count == 6,
           let hz = Int(body.dropFirst(2)) {
            clarifierOffset += body.hasPrefix("RU") ? hz : -hz
            return nil
        }
        if body.hasPrefix("AC00"), body.count == 5,
           let digit = body.last?.wholeNumberValue {
            switch digit {
            case 2: tuner = .tuning; txState = "2"; tuneReadsRemaining = 2
            case 1: tuner = .on
            default: tuner = .off
            }
            return nil
        }
        if body.hasPrefix("KM"), body.count >= 3,
           let channel = body.dropFirst(2).first?.wholeNumberValue {
            keyerMemories[channel] = String(body.dropFirst(3))
            return nil
        }
        if body.hasPrefix("KY"), body.count == 3 {
            return nil // playback trigger; not modeled further
        }
        if body.hasPrefix("RM"), body.count == 3 {
            let meter = body.last!
            let value: Int
            switch meter {
            case "6": value = tuner == .tuning ? 80 : 30 // SWR
            case "4": value = 60                          // ALC
            case "5": value = power * 2                   // PO (raw-ish)
            default: value = sMeter
            }
            return "RM\(meter)" + String(format: "%03d;", value)
        }
        if body.hasPrefix("EX") {
            return respondEX(body: body)
        }
        return respondSetting(body: body)
    }

    private mutating func respondEX(body: String) -> String? {
        let rest = String(body.dropFirst(2))
        guard rest.count >= 4 else { return "?;" }
        let number = String(rest.prefix(4))
        let value = String(rest.dropFirst(4))
        if value.isEmpty { return "EX\(number)\(menu[number] ?? "0");" }
        guard value.allSatisfy(\.isNumber) else { return "?;" }
        menu[number] = value
        return nil
    }

    private mutating func respondSetting(body: String) -> String? {
        for (prefix, digits) in Self.settingDigits {
            guard body.hasPrefix(prefix) else { continue }
            let rest = String(body.dropFirst(prefix.count))
            if rest.isEmpty {
                guard let value = settings[prefix] else { return "?;" }
                return "\(prefix)\(String(format: "%0\(digits)d", value));"
            }
            guard rest.count == digits, let value = Int(rest) else {
                return "?;"
            }
            settings[prefix] = value
            return nil
        }
        return "?;"
    }
}
