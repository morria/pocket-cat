// QMX-specific CAT wrappers, layered on CATBridgeKit's raw-command escape
// hatch. Wire formats per the QMX CAT programming manual (fw 1_02_006),
// mirrored in esp32s3/docs/references/qmx-cat.md.

import CATBridgeKit
import Foundation

/// The QMX's four MD modes (sideband is separate — `Sideband` below).
public enum QMXMode: Character, CaseIterable, Sendable, Identifiable {
    case cw = "3"
    case digi = "6"
    case cwReverse = "7"
    case fskReverse = "9"

    public var id: Character { rawValue }

    public var title: String {
        switch self {
        case .cw: "CW"
        case .digi: "DIGI"
        case .cwReverse: "CW-R"
        case .fskReverse: "FSK-R"
        }
    }

    /// The library's mode value carried in snapshots for this MD code.
    public var operatingMode: OperatingMode {
        switch self {
        case .cw: .cw
        case .digi: .rtty
        case .cwReverse: .cwReverse
        case .fskReverse: .rttyReverse
        }
    }

    public init?(operatingMode: OperatingMode) {
        switch operatingMode {
        case .cw: self = .cw
        case .rtty: self = .digi
        case .cwReverse: self = .cwReverse
        case .rttyReverse: self = .fskReverse
        default: return nil
        }
    }
}

public enum Sideband: String, Sendable, CaseIterable {
    case usb = "USB"
    case lsb = "LSB"
}

public enum VFOMode: Int, Sendable, CaseIterable {
    case vfoA = 0
    case vfoB = 1
    case split = 2
}

extension TransceiverSession {
    // MARK: - Raw helpers

    /// One read-style command; returns the reply body between the echoed
    /// prefix and the terminator (`"RT1;"` → `"1"`).
    func qmxRead(_ wire: String, prefix: String) async throws -> String {
        guard let reply = try await rawCommand(wire, expectsReply: true,
                                               isIdempotent: true),
              reply.hasPrefix(prefix), reply.hasSuffix(";")
        else { throw CATBridgeError.malformedResponse(wire) }
        return String(reply.dropFirst(prefix.count).dropLast())
    }

    // MARK: - Sideband (Q1 — session-only, not saved to EEPROM)

    public func readSideband() async throws -> Sideband {
        try await qmxRead("Q1;", prefix: "Q1") == "1" ? .lsb : .usb
    }

    public func setSideband(_ sideband: Sideband) async throws {
        _ = try await rawCommand("Q1\(sideband == .lsb ? 1 : 0);",
                                 expectsReply: false)
    }

    // MARK: - RIT (RT status; RU/RD absolute-or-relative per radio config)

    public func readRITEnabled() async throws -> Bool {
        try await qmxRead("RT;", prefix: "RT") == "1"
    }

    public func setRIT(enabled: Bool) async throws {
        _ = try await rawCommand("RT\(enabled ? 1 : 0);", expectsReply: false)
    }

    /// Offset in Hz; sign picks `RU`/`RD`. Whether the radio treats it as
    /// absolute or relative follows its "CAT RU and RD" System setting.
    public func sendRITOffset(_ hz: Int) async throws {
        let op = hz < 0 ? "RD" : "RU"
        _ = try await rawCommand("\(op)\(String(format: "%03d", abs(hz)));",
                                 expectsReply: false)
    }

    public func clearRIT() async throws {
        _ = try await rawCommand("RC;", expectsReply: false)
    }

    /// Current RIT offset, from the IF composite (chars 13–18: ±9999 Hz).
    public func readRITOffset() async throws -> Int {
        let body = try await qmxRead("IF;", prefix: "IF")
        let chars = Array(body)
        guard chars.count >= 22 else {
            throw CATBridgeError.malformedResponse("IF")
        }
        let field = String(chars[16...20]).trimmingCharacters(in: .whitespaces)
        return Int(field) ?? 0
    }

    // MARK: - Split / VFO mode (SP, FR/FT), VFO B (FB)

    public func readSplit() async throws -> Bool {
        try await qmxRead("SP;", prefix: "SP") == "1"
    }

    public func setSplit(_ on: Bool) async throws {
        _ = try await rawCommand("SP\(on ? 1 : 0);", expectsReply: false)
    }

    public func setVFOMode(_ mode: VFOMode) async throws {
        _ = try await rawCommand("FR\(mode.rawValue);", expectsReply: false)
    }

    public func readVFOB() async throws -> Frequency {
        let body = try await qmxRead("FB;", prefix: "FB")
        guard body.count == 11, let hz = UInt64(body) else {
            throw CATBridgeError.malformedResponse("FB")
        }
        return Frequency(hz: hz)
    }

    public func setVFOB(_ frequency: Frequency) async throws {
        guard let digits = frequency.catDigits(width: 11) else {
            throw CATBridgeError.invalidArgument("frequency out of range")
        }
        _ = try await rawCommand("FB\(digits);", expectsReply: false)
    }

    // MARK: - Meters (all read-only on the QMX)

    /// AGC gain attenuation, dB (`SA`).
    public func readAGCMeter() async throws -> Int {
        guard let value = Int(try await qmxRead("SA;", prefix: "SA")) else {
            throw CATBridgeError.malformedResponse("SA")
        }
        return value
    }

    /// SWR in hundredths (`SW121;` → 1.21). nil while receiving — the
    /// radio answers an empty `SW;`.
    public func readSWR() async throws -> Double? {
        let body = try await qmxRead("SW;", prefix: "SW")
        guard !body.isEmpty else { return nil }
        guard let hundredths = Int(body) else {
            throw CATBridgeError.malformedResponse("SW")
        }
        return Double(hundredths) / 100.0
    }

    /// Current MD mode as the QMX's own four-mode type.
    public func readQMXMode() async throws -> QMXMode {
        let body = try await qmxRead("MD;", prefix: "MD")
        guard let code = body.first, let mode = QMXMode(rawValue: code) else {
            throw CATBridgeError.malformedResponse("MD")
        }
        return mode
    }

    // MARK: - Odds and ends

    public func readFirmwareVersion() async throws -> String {
        try await qmxRead("VN;", prefix: "VN")
    }

    /// Drain the QMX's 40-char CW decoder buffer (`TB`). Returns the
    /// decoded text (may be empty).
    public func readDecodedCW() async throws -> String {
        let body = try await qmxRead("TB;", prefix: "TB")
        // TBtnns; → t = keyer state, nn = count, s… = text
        guard body.count >= 3, let count = Int(body.dropFirst().prefix(2))
        else { throw CATBridgeError.malformedResponse("TB") }
        return String(body.dropFirst(3).prefix(count))
    }
}
