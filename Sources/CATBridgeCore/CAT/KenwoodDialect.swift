// Kenwood TS-480-subset dialect for the QRP Labs QMX
// (esp32s3/docs/references/qmx-cat.md): 11-digit Hz frequencies, single-digit
// MD codes, TX;/RX; sets with NO reply and NO safe PTT read (TX; keys the
// radio), ID; → ID020;.

public struct KenwoodDialect: CATDialect {
    public let radioModel: RadioModel
    public let idReply: String

    public init(model: RadioModel = .qmx, idReply: String = "ID020;") {
        self.radioModel = model
        self.idReply = idReply
    }

    public static let qmx = KenwoodDialect()

    public var capabilities: RadioCapabilities {
        // qmx-cat.md lists SM and PC in the QMX's TS-480 subset; PC "may be
        // fixed/limited" on QMX hardware — confirm at bring-up. No EX menu.
        [.frequencyControl, .modeControl, .ptt, .keyerText, .sMeter,
         .rfPowerControl]
    }

    // Kenwood mode table (Hamlib kenwood_mode_table[]).
    static let modeForCode: [Character: OperatingMode] = [
        "1": .lsb, "2": .usb, "3": .cw, "4": .fm, "5": .am,
        "6": .rtty, "7": .cwReverse, "9": .rttyReverse,
    ]
    static let codeForMode: [OperatingMode: Character] = {
        var out: [OperatingMode: Character] = [:]
        for (code, mode) in modeForCode { out[mode] = code }
        return out
    }()

    public var pttOn: CATCommand {
        CATCommand(wire: "TX;", replyPrefix: nil, isIdempotent: false,
                   isPTTOn: true)
    }

    public var pttOff: CATCommand {
        CATCommand(wire: "RX;", replyPrefix: nil, isIdempotent: false)
    }

    public var failsafeString: String { "RX;" }

    public var readID: CATCommand {
        CATCommand(wire: "ID;", replyPrefix: "ID")
    }

    public var readInfo: CATCommand {
        CATCommand(wire: "IF;", replyPrefix: "IF")
    }

    public var readFrequency: CATCommand {
        CATCommand(wire: "FA;", replyPrefix: "FA")
    }

    public var readMode: CATCommand {
        CATCommand(wire: "MD;", replyPrefix: "MD")
    }

    /// Kenwood `TX;` is a SET (it keys the radio) — never poll it.
    public var readPTT: CATCommand? { nil }

    public var readSMeter: CATCommand? {
        CATCommand(wire: "SM0;", replyPrefix: "SM0")
    }

    // MARK: - RF power (PC; qmx-cat.md "may be fixed/limited on QMX")

    public var readPower: CATCommand? {
        CATCommand(wire: "PC;", replyPrefix: "PC")
    }

    /// TS-480 wire range is 005–100; the QMX's real output ceiling (~5 W)
    /// is firmware-dependent — the radio clamps or rejects what it can't do.
    public var powerRange: ClosedRange<Int>? { 5...100 }

    public func setPower(watts: Int) throws -> CATCommand {
        guard let range = powerRange, range.contains(watts) else {
            throw CATBridgeError.invalidArgument(
                "power \(watts) W outside \(powerRange.map(String.init(describing:)) ?? "supported") range")
        }
        return CATCommand(wire: String(format: "PC%03d;", watts),
                          replyPrefix: nil)
    }

    // MARK: - Settings (KS is the QMX's only listed level control)

    /// TS-480 `KS` is 010–060 WPM; QMX limits unconfirmed until bring-up.
    static let keyerSpeedRange = 4...60

    public func readSetting(_ setting: RigSetting) -> CATCommand? {
        guard setting == .keyerSpeed else { return nil }
        return CATCommand(wire: "KS;", replyPrefix: "KS")
    }

    public func setSetting(_ setting: RigSetting,
                           to value: Int) throws -> CATCommand {
        guard setting == .keyerSpeed else {
            throw CATBridgeError.unsupportedSetting(setting)
        }
        guard Self.keyerSpeedRange.contains(value) else {
            throw CATBridgeError.invalidArgument(
                "keyerSpeed \(value) outside \(Self.keyerSpeedRange)")
        }
        return CATCommand(wire: String(format: "KS%03d;", value),
                          replyPrefix: nil)
    }

    public func settingRange(_ setting: RigSetting) -> ClosedRange<Int>? {
        setting == .keyerSpeed ? Self.keyerSpeedRange : nil
    }

    public func setFrequency(_ frequency: Frequency) throws -> CATCommand {
        guard let digits = frequency.catDigits(width: 11) else {
            throw CATBridgeError.invalidArgument(
                "frequency \(frequency) exceeds 11-digit Kenwood field")
        }
        return CATCommand(wire: "FA\(digits);", replyPrefix: nil)
    }

    public func setMode(_ mode: OperatingMode) throws -> CATCommand {
        guard let code = Self.codeForMode[mode] else {
            throw CATBridgeError.unsupportedMode(mode)
        }
        return CATCommand(wire: "MD\(code);", replyPrefix: nil)
    }

    public func keyerText(_ text: String) throws -> CATCommand {
        guard text.allSatisfy({ $0.isASCII && $0 != ";" }), !text.isEmpty
        else {
            throw CATBridgeError.invalidArgument("keyer text must be ASCII")
        }
        return CATCommand(wire: "KY \(text);", replyPrefix: nil,
                          isIdempotent: false)
    }

    public func parse(reply: String, to command: CATCommand) throws -> CATValue {
        try requireTerminated(reply)
        switch command.replyPrefix {
        case "ID":
            return .id(reply)
        case "FA":
            return .frequency(try parseFrequency(reply))
        case "MD":
            return .mode(try parseMode(reply))
        case "IF":
            return .info(try parseInfo(reply))
        case "SM0":
            return .sMeter(try parseSMeter(reply))
        case "PC":
            return .power(try parsePower(reply))
        case "KS":
            return .setting(.keyerSpeed, try parseKeyerSpeed(reply))
        default:
            return .raw(reply)
        }
    }

    public func parseUnsolicited(_ frame: String) -> CATValue? {
        if frame.hasPrefix("IF"), let info = try? parseInfo(frame) {
            return .info(info)
        }
        if frame.hasPrefix("FA"), let f = try? parseFrequency(frame) {
            return .frequency(f)
        }
        return nil
    }

    // MARK: - Field parsers

    private func parseFrequency(_ reply: String) throws -> Frequency {
        // FA + 11 digits + ;
        let chars = Array(reply)
        guard chars.count == 14, reply.hasPrefix("FA"),
              let hz = UInt64(String(chars[2...12]))
        else { throw CATBridgeError.malformedResponse(reply) }
        return Frequency(hz: hz)
    }

    private func parseMode(_ reply: String) throws -> OperatingMode {
        // MD<code>;
        let chars = Array(reply)
        guard chars.count == 4, reply.hasPrefix("MD"),
              let mode = Self.modeForCode[chars[2]]
        else { throw CATBridgeError.malformedResponse(reply) }
        return mode
    }

    private func parseSMeter(_ reply: String) throws -> Int {
        // TS-480: SM0nnnn; — parse lenient on width in case QMX firmware
        // answers fewer digits (confirm at bring-up).
        guard reply.hasPrefix("SM0"), reply.hasSuffix(";"),
              let value = Int(reply.dropFirst(3).dropLast())
        else { throw CATBridgeError.malformedResponse(reply) }
        return value
    }

    private func parsePower(_ reply: String) throws -> Int {
        // PCnnn;
        let chars = Array(reply)
        guard chars.count == 6, reply.hasPrefix("PC"),
              let watts = Int(String(chars[2...4]))
        else { throw CATBridgeError.malformedResponse(reply) }
        return watts
    }

    private func parseKeyerSpeed(_ reply: String) throws -> Int {
        // KSnnn;
        guard reply.hasPrefix("KS"), reply.hasSuffix(";"),
              let wpm = Int(reply.dropFirst(2).dropLast())
        else { throw CATBridgeError.malformedResponse(reply) }
        return wpm
    }

    private func parseInfo(_ reply: String) throws -> RigInfo {
        // IF | freq(11) | spaces(5) | rit(5) | flags(5) | tx(1) | mode(1) …
        let chars = Array(reply)
        guard chars.count >= 31, reply.hasPrefix("IF"),
              let hz = UInt64(String(chars[2...12]))
        else { throw CATBridgeError.malformedResponse(reply) }
        let tx = chars[28] == "1"
        let mode = Self.modeForCode[chars[29]]
        return RigInfo(frequency: Frequency(hz: hz), mode: mode,
                       isTransmitting: tx)
    }
}
