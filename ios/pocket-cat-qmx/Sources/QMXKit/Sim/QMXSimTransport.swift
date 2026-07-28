// A BridgeTransport impersonating the Pocket Cat bridge with a QMX
// attached — the whole app runs against it with no hardware (tests,
// previews, demo mode). Wire behavior follows the QMX CAT programming
// manual fw 1_02_006, including a representative MM/ML menu tree.

import CATBridgeCore
import Foundation

public actor QMXSimTransport: BridgeTransport {
    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation:
        AsyncStream<TransportEvent>.Continuation

    private var rig: QMXSimRig
    private var connected = false
    private var linkBaud: UInt32 = 4800 // cosmetic: QMX is native USB

    public init(rig: QMXSimRig = QMXSimRig()) {
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
        stopSpectrum()
    }

    public func writeCAT(_ data: Data) async throws {
        guard connected else { throw CATBridgeError.connectionLost }
        for reply in rig.feed(data) {
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

    public var rigState: QMXSimRig { rig }

    public func setRig(_ transform: @Sendable (inout QMXSimRig) -> Void) {
        transform(&rig)
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
        case CtrlOp.setSpectrum.rawValue where frame.payload.count == 4:
            let p = [UInt8](frame.payload)
            let bins = Int(p[1]) | (Int(p[2]) << 8)
            let fps = Int(p[3])
            if p[0] == 0 {
                stopSpectrum()
                ack(frame.op)
            } else if ![64, 128, 256, 512].contains(bins)
                        || !(1...30).contains(fps) {
                emit(CtrlFrame(op: CtrlOp.nak.rawValue,
                               payload: Data([frame.op,
                                              CtrlErrCode.badArgument.rawValue])))
            } else {
                startSpectrum(bins: bins, fps: fps)
                ack(frame.op)
            }
        default:
            emit(CtrlFrame(op: CtrlOp.nak.rawValue,
                           payload: Data([frame.op,
                                          CtrlErrCode.unknownOp.rawValue])))
        }
    }

    // MARK: - Synthetic spectrum stream (docs/qmx-panadapter.md M3)

    private var spectrumTask: Task<Void, Never>?
    private var spectrumSeq: UInt8 = 0

    private func startSpectrum(bins: Int, fps: Int) {
        stopSpectrum()
        spectrumTask = Task { [weak self] in
            var phase = 0.0
            while !Task.isCancelled {
                await self?.emitSpectrumFrame(bins: bins, phase: phase)
                phase += 0.02
                try? await Task.sleep(for: .milliseconds(1000 / fps))
            }
        }
    }

    private func stopSpectrum() {
        spectrumTask?.cancel()
        spectrumTask = nil
    }

    private func emitSpectrumFrame(bins: Int, phase: Double) {
        guard connected else { return }
        // A wandering carrier over a ~-105 dBFS noise floor.
        let centre = Double(bins) * (0.5 + 0.3 * sin(phase))
        var trace = [UInt8](repeating: 0, count: bins)
        for i in 0..<bins {
            let noise = 210.0 + Double.random(in: -6...6)
            let d = Double(i) - centre
            let peak = 60.0 + 8.0 * exp(-d * d / 4.0) * 18.75
            trace[i] = UInt8(max(0, min(255, min(noise, 270.0 - peak))))
        }
        let seq = spectrumSeq
        spectrumSeq &+= 1
        // Fragment exactly like the firmware at mtu_payload 244.
        let mtu = 244
        var first = 0
        var frag = 0
        var frags: [[UInt8]] = []
        while first < bins {
            let cap = frag == 0 ? mtu - 12 : mtu - 5
            let count = min(cap, bins - first)
            var out: [UInt8] = [seq, UInt8(frag), 0]
            if frag == 0 {
                out.append(0)
                out.append(contentsOf: [0, 0])
                out.append(contentsOf: [UInt8(bins & 0xFF),
                                        UInt8(bins >> 8)])
                out.append(contentsOf: [0x80, 0xBB, 0, 0]) // 48000 LE
            } else {
                out.append(contentsOf: [UInt8(first & 0xFF),
                                        UInt8(first >> 8)])
            }
            out.append(contentsOf: trace[first..<(first + count)])
            frags.append(out)
            first += count
            frag += 1
        }
        for var f in frags {
            f[2] = UInt8(frags.count)
            continuation.yield(.spectrumData(Data(f)))
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
        d.append(3) // radio id: qmxCDC
        d.append(contentsOf: le(linkBaud))
        d.append(contentsOf: le(0))
        d.append(contentsOf: le(0))
        d.append(contentsOf: [1, 0, 0]) // fw 1.0, reset reason
        d.append(contentsOf: le(180_000))
        return d
    }
}

/// The simulated QMX: pure state + command→reply logic, value-typed so
/// tests can snapshot and mutate freely.
public struct QMXSimRig: Sendable {
    // Operating state
    public var vfoA: UInt64 = 14_060_000
    public var vfoB: UInt64 = 7_030_000
    public var modeCode: Character = "3" // CW
    public var transmitting = false
    public var lsb = false               // Q1 sideband
    public var split = false             // SP
    public var ritOn = false
    public var ritOffset = 0             // Hz, ±9999
    public var ritAbsolute = true        // "CAT RU and RD" behavior
    public var sMeterDB = 12
    public var powerTenths = 45          // PC45; = 4.5 W (GET-only)
    public var agcDB = 23
    public var swrHundredths = 121       // 1.21:1, empty reply while RX
    public var keyerSpeed = 20
    public var iqMode = false // Q9
    /// Pending text for the CW decoder (`TB`). Tests and the simulated
    /// band push into this; `KY` also feeds it, standing in for the radio
    /// decoding its own sidetone.
    public var decodeBuffer = ""
    /// Seconds since midnight, as set by `TM`. Starts deliberately wrong so
    /// clock-sync tests can see it move.
    public var clockSeconds = 0
    /// Every digi tone the radio was told to key, in order (`TA`). `nil`
    /// marks `TA0;` — the unkey.
    public var toneLog: [Double?] = []

    /// A menu-tree node; grids carry one value per column.
    public struct SimNode: Sendable {
        public var name: String
        public var kind: Int      // QMXMenuNode.Kind raw
        public var meta: Int      // field length or list type
        public var columns: Int?
        public var children: [SimNode]
        public var values: [String]

        public init(name: String, kind: Int, meta: Int = 0,
                    columns: Int? = nil, children: [SimNode] = [],
                    values: [String] = []) {
            self.name = name
            self.kind = kind
            self.meta = meta
            self.columns = columns
            self.children = children
            self.values = values
        }
    }

    public var menuRoot: [SimNode] = QMXSimRig.defaultTree()
    /// listType → permitted values (ML answers).
    public var listTables: [Int: [String]] = [
        0: ["DISABLED", "ENABLED"],
        3: ["Straight", "IAMBIC A", "IAMBIC B", "Ultimatic"],
        4: ["Absolute", "Relative"],
        5: ["CW", "WSPR"],
    ]

    var pending = ""

    public init() {}

    // MARK: - Default tree (representative subset of the real radio's)

    static func defaultTree() -> [SimNode] {
        func leaf(_ name: String, kind: Int, meta: Int, _ value: String)
            -> SimNode {
            SimNode(name: name, kind: kind, meta: meta, values: [value])
        }
        return [
            SimNode(name: "Audio", kind: 0, children: [
                SimNode(name: "AGC settings", kind: 0, children: [
                    leaf("AGC enable", kind: 5, meta: 0, "ENABLED"),
                    leaf("Threshold S", kind: 3, meta: 2, "4"),
                    leaf("Attack", kind: 3, meta: 3, "10"),
                    leaf("Decay", kind: 3, meta: 3, "50"),
                    leaf("Hang", kind: 3, meta: 3, "30"),
                ]),
                leaf("Sidetone volume", kind: 3, meta: 3, "50"),
                leaf("Sidetone frequency", kind: 3, meta: 4, "600"),
            ]),
            SimNode(name: "CW", kind: 0, children: [
                SimNode(name: "CW Keyer", kind: 0, children: [
                    leaf("Keyer mode", kind: 5, meta: 3, "IAMBIC A"),
                    leaf("Keyer speed", kind: 3, meta: 2, "20"),
                    leaf("Keyer swap", kind: 5, meta: 0, "DISABLED"),
                    leaf("Keyer weight", kind: 3, meta: 3, "500"),
                ]),
                SimNode(name: "CW decoder", kind: 0, children: [
                    leaf("Enable RX decode", kind: 5, meta: 0, "ENABLED"),
                    leaf("Enable TX decode", kind: 5, meta: 0, "DISABLED"),
                ]),
                // Numeric row names: addressable only by index (manual §)
                SimNode(name: "Choose filters", kind: 0, children: [
                    leaf("50", kind: 7, meta: 0, "ENABLED"),
                    leaf("100", kind: 7, meta: 0, "ENABLED"),
                    leaf("200", kind: 7, meta: 0, "ENABLED"),
                    leaf("300", kind: 7, meta: 0, "DISABLED"),
                ]),
                leaf("Practice mode", kind: 5, meta: 0, "DISABLED"),
                leaf("QSK delay", kind: 3, meta: 3, "10"),
            ]),
            SimNode(name: "Digi interface", kind: 0, children: [
                leaf("Rise threshold", kind: 3, meta: 2, "80"),
                leaf("Fall threshold", kind: 3, meta: 2, "60"),
                leaf("IQ mode", kind: 5, meta: 0, "DISABLED"),
            ]),
            SimNode(name: "System config", kind: 0, children: [
                SimNode(name: "CAT", kind: 0, children: [
                    leaf("Serial baud", kind: 3, meta: 7, "115200"),
                    leaf("CAT timeout enable", kind: 5, meta: 0, "DISABLED"),
                    leaf("CAT timeout", kind: 3, meta: 3, "0"),
                    leaf("CAT RU and RD", kind: 5, meta: 4, "Absolute"),
                    leaf("TS480 compat", kind: 5, meta: 0, "DISABLED"),
                ]),
                SimNode(name: "Factory reset", kind: 1),
                leaf("TCXO frequency", kind: 3, meta: 8, "25000000"),
            ]),
            SimNode(name: "Band config.", kind: 0, columns: 3, children: [
                SimNode(name: "Band name (m)", kind: 3, meta: 4,
                        values: ["80", "40", "20"]),
                SimNode(name: "RF gain (dB)", kind: 3, meta: 2,
                        values: ["54", "54", "74"]),
                SimNode(name: "Frequency center", kind: 3, meta: 8,
                        values: ["3573000", "7074000", "14074000"]),
                SimNode(name: "Transmit", kind: 5, meta: 0,
                        values: ["ENABLED", "ENABLED", "ENABLED"]),
            ]),
            SimNode(name: "Beacon", kind: 0, children: [
                leaf("Beacon enable", kind: 5, meta: 0, "DISABLED"),
                leaf("Mode", kind: 5, meta: 5, "WSPR"),
                leaf("Callsign", kind: 2, meta: 12, "N0CALL"),
                leaf("Power dBm", kind: 3, meta: 2, "37"),
            ]),
        ]
    }

    // MARK: - Byte pump

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
        let freq = String(format: "%011d", vfoA)
        let rit = String(format: "%@%04d", ritOffset < 0 ? "-" : "+",
                         abs(ritOffset))
        let tx = transmitting ? "1" : "0"
        let sp = split ? "1" : "0"
        return "IF\(freq)     \(rit)\(ritOn ? 1 : 0)000\(tx)\(modeCode)0"
            + "0\(sp)00 ;"
    }

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func respond(to cmd: String) -> String? {
        switch cmd {
        case "ID;": return "ID020;"
        case "OM;": return "OMQC;"
        case "IF;": return ifAnswer()
        case "FA;": return String(format: "FA%011d;", vfoA)
        case "FB;": return String(format: "FB%011d;", vfoB)
        case "MD;": return "MD\(modeCode);"
        case "TX;", "TQ1;": transmitting = true; return nil
        case "RX;", "TQ0;": transmitting = false; return nil
        case "TQ;": return "TQ\(transmitting ? 1 : 0);"
        case "SM;", "SM0;": return "SM\(sMeterDB);"
        case "PC;": return "PC\(powerTenths);"
        case "KS;": return String(format: "KS%03d;", keyerSpeed)
        case "Q1;": return "Q1\(lsb ? 1 : 0);"
        case "Q9;": return "Q9\(iqMode ? 1 : 0);"
        case "SP;": return "SP\(split ? 1 : 0);"
        case "RT;": return "RT\(ritOn ? 1 : 0);"
        case "RC;": ritOffset = 0; return nil
        case "SA;": return "SA\(agcDB);"
        case "SW;": return transmitting ? "SW\(swrHundredths);" : "SW;"
        case "VN;": return "VN1_02_006QMX;"
        case "TM;":
            return String(format: "TM%02d%02d%02d;", clockSeconds / 3_600,
                          (clockSeconds / 60) % 60, clockSeconds % 60)
        case "TA0;":
            transmitting = false
            toneLog.append(nil)
            return nil
        case "TB;":
            // TB<keyer state><2-digit count><text>; — the radio hands over
            // at most its 40-char buffer and drops what it gives us.
            let chunk = String(decodeBuffer.prefix(40))
            decodeBuffer.removeFirst(chunk.count)
            return "TB\(transmitting ? 1 : 0)"
                + String(format: "%02d", chunk.count) + chunk + ";"
        default:
            return respondPrefixed(to: cmd)
        }
    }

    private mutating func respondPrefixed(to cmd: String) -> String? {
        let body = String(cmd.dropLast())
        if body.hasPrefix("MM") || body.hasPrefix("ML") {
            return respondMenu(body: body)
        }
        if body.hasPrefix("FA"), let hz = UInt64(body.dropFirst(2)) {
            vfoA = hz
            return nil
        }
        if body.hasPrefix("FB"), let hz = UInt64(body.dropFirst(2)) {
            vfoB = hz
            return nil
        }
        if body.hasPrefix("MD"), body.count == 3 {
            let code = body.last!
            guard "3679".contains(code) else { return "?;" }
            modeCode = code
            return nil
        }
        if body.hasPrefix("Q1"), body.count == 3 {
            lsb = body.last == "1"
            return nil
        }
        if body.hasPrefix("Q9"), body.count == 3 {
            iqMode = body.last == "1"
            return nil
        }
        if body.hasPrefix("SP"), body.count == 3 {
            split = body.last == "1"
            return nil
        }
        if body.hasPrefix("RT"), body.count == 3 {
            ritOn = body.last == "1"
            return nil
        }
        if body.hasPrefix("RU") || body.hasPrefix("RD"),
           let hz = Int(body.dropFirst(2)) {
            let signed = body.hasPrefix("RU") ? hz : -hz
            ritOffset = ritAbsolute ? signed : ritOffset + signed
            return nil
        }
        if body.hasPrefix("KS"), let wpm = Int(body.dropFirst(2)) {
            keyerSpeed = wpm
            return nil
        }
        if body.hasPrefix("KY ") {
            // The real radio decodes its own sidetone, so keyed text comes
            // back round through TB. Instant here; on the air it arrives at
            // the keyer's speed.
            decodeBuffer += String(body.dropFirst(3)).uppercased() + " "
            return nil
        }
        if body.hasPrefix("TM"), body.count == 8,
           let hours = Int(body.dropFirst(2).prefix(2)),
           let minutes = Int(body.dropFirst(4).prefix(2)),
           let seconds = Int(body.suffix(2)) {
            clockSeconds = hours * 3_600 + minutes * 60 + seconds
            return nil
        }
        if body.hasPrefix("TA"), let hz = Double(body.dropFirst(2)), hz > 0 {
            transmitting = true
            toneLog.append(hz)
            return nil
        }
        if body.hasPrefix("PC"), body.count > 2 { return "?;" } // GET-only
        if body.hasPrefix("FR") || body.hasPrefix("FT"), body.count == 3 {
            split = body.last == "2"
            return nil
        }
        return "?;"
    }

    // MARK: - MM/ML menu manager

    private mutating func respondMenu(body: String) -> String? {
        if body.hasPrefix("ML") {
            guard let listType = Int(body.dropFirst(2)),
                  let options = listTables[listType] else { return "?;" }
            return "ML\(options.joined(separator: "|"));"
        }
        let request = String(body.dropFirst(2))
        if request.hasSuffix("?") { // discovery
            return discover(String(request.dropLast()))
        }
        if let eq = request.firstIndex(of: "=") { // set
            let path = String(request[..<eq])
            let value = String(request[request.index(after: eq)...])
            return setValue(path: path, value: value)
        }
        return getValue(path: request)
    }

    private func discover(_ request: String) -> String {
        var components = request.split(separator: "|",
                                       omittingEmptySubsequences: false)
            .map(String.init)
        guard let indexPart = components.popLast(),
              let index = Int(indexPart) else { return "?;" }
        let siblings: [SimNode]
        if components.isEmpty {
            siblings = menuRoot
        } else {
            guard let parent = resolve(components), parent.kind == 0 else {
                return "?;"
            }
            siblings = parent.children
        }
        guard index >= 0, index < siblings.count else { return "?;" }
        let node = siblings[index]
        let suffix = node.columns.map { "[\($0)]" } ?? ""
        return "MM\(node.kind)|\(node.meta)|\(node.name)\(suffix);"
    }

    private mutating func setValue(path: String, value: String) -> String? {
        guard let location = locate(path) else { return "?;" }
        let (indexPath, column) = location
        var node = node(at: indexPath)
        guard [2, 3, 4, 5, 7].contains(node.kind) else { return "?;" }
        if node.kind == 5 || node.kind == 7 {
            guard listTables[node.meta]?.contains(where: {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }) == true else { return "?;" }
        }
        let slot = column ?? 0
        guard slot >= 0, slot < node.values.count else { return "?;" }
        node.values[slot] = value
        replace(at: indexPath, with: node)
        return nil
    }

    private func getValue(path: String) -> String {
        guard let location = locate(path) else { return "?;" }
        let (indexPath, column) = location
        let node = node(at: indexPath)
        guard node.kind != 0, node.kind != 1 else { return "?;" }
        let slot = column ?? 0
        guard slot >= 0, slot < node.values.count else { return "?;" }
        return "MM\(node.values[slot]);"
    }

    // MARK: - Path resolution

    /// Resolve name-or-index components (case-insensitive; numeric-named
    /// items only match by index, per the manual).
    private func locate(_ path: String) -> (indexPath: [Int], column: Int?)? {
        var components = path.split(separator: "|",
                                    omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty else { return nil }
        var column: Int?
        if var last = components.last, last.hasSuffix("]"),
           let open = last.lastIndex(of: "[") {
            column = Int(last[last.index(after: open)..<last.index(
                before: last.endIndex)])
            last = String(last[..<open])
            components[components.count - 1] = last
        }
        var siblings = menuRoot
        var indexPath: [Int] = []
        for component in components {
            let match: Int?
            if let index = Int(component) {
                match = index < siblings.count ? index : nil
            } else {
                match = siblings.firstIndex {
                    !$0.name.allSatisfy(\.isNumber)
                        && $0.name.caseInsensitiveCompare(component)
                            == .orderedSame
                }
            }
            guard let found = match else { return nil }
            indexPath.append(found)
            siblings = siblings[found].children
        }
        return (indexPath, column)
    }

    private func resolve(_ components: [String]) -> SimNode? {
        guard let location = locate(components.joined(separator: "|")) else {
            return nil
        }
        return node(at: location.indexPath)
    }

    private func node(at indexPath: [Int]) -> SimNode {
        var current = menuRoot[indexPath[0]]
        for index in indexPath.dropFirst() {
            current = current.children[index]
        }
        return current
    }

    private mutating func replace(at indexPath: [Int], with node: SimNode) {
        func rewrite(_ nodes: inout [SimNode], _ path: ArraySlice<Int>) {
            guard let head = path.first else { return }
            if path.count == 1 {
                nodes[head] = node
            } else {
                rewrite(&nodes[head].children, path.dropFirst())
            }
        }
        rewrite(&menuRoot, indexPath[...])
    }
}
