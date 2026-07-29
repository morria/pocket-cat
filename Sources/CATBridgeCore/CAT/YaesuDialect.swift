// Yaesu ASCII CAT dialect (FT-891; the FTX-1 parameterizes it).
//
// Mode codes and formats per esp32s3/docs/references/yaesu-cat-ft891.md,
// grounded in Hamlib's newcat_mode_conv[] — 9-digit Hz frequencies,
// MD0<code>;, TX1;/TX0; sets with a TX; read, ID; → ID0650;.
//
// IF; layout note: the fixed offsets below match the project's radio
// simulators; they carry a bring-up caveat against the real rig
// (esp32s3/docs/implementation.md §7.5 item 1 applies to the app side too).

public struct YaesuDialect: CATDialect {
    public let radioModel: RadioModel
    public let idReply: String

    public init(model: RadioModel = .ft891, idReply: String = "ID0650;") {
        self.radioModel = model
        self.idReply = idReply
    }

    public static let ft891 = YaesuDialect(model: .ft891, idReply: "ID0650;")
    /// FTX-1 ID code is unconfirmed until hardware bring-up; the simulator
    /// uses ID0800; as the placeholder.
    public static let ftx1 = YaesuDialect(model: .ftx1, idReply: "ID0800;")

    public var capabilities: RadioCapabilities {
        [.frequencyControl, .modeControl, .ptt, .sMeter, .keyerText,
         .rfPowerControl, .autoInformation, .menuAccess]
    }

    /// Yaesu Auto-Information: the rig pushes state frames unsolicited.
    /// Sets, answered with silence like other Yaesu sets.
    public var enableAutoInformation: CATCommand? {
        CATCommand(wire: "AI1;", replyPrefix: nil)
    }

    public var disableAutoInformation: CATCommand? {
        CATCommand(wire: "AI0;", replyPrefix: nil)
    }

    // Yaesu newcat mode table (Hamlib newcat_mode_conv[]).
    static let modeForCode: [Character: OperatingMode] = [
        "1": .lsb, "2": .usb, "3": .cw, "4": .fm, "5": .am,
        "6": .rtty, "7": .cwReverse, "8": .dataLSB, "9": .rttyReverse,
        "A": .dataFM, "B": .fmNarrow, "C": .dataUSB, "D": .amNarrow,
        "E": .c4fm, "F": .dataFMNarrow,
    ]
    static let codeForMode: [OperatingMode: Character] = {
        var out: [OperatingMode: Character] = [:]
        for (code, mode) in modeForCode { out[mode] = code }
        return out
    }()

    public var pttOn: CATCommand {
        CATCommand(wire: "TX1;", replyPrefix: nil, isIdempotent: false,
                   isPTTOn: true)
    }

    public var pttOff: CATCommand {
        CATCommand(wire: "TX0;", replyPrefix: nil, isIdempotent: false)
    }

    public var failsafeString: String { "TX0;" }

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
        CATCommand(wire: "MD0;", replyPrefix: "MD0")
    }

    public var readPTT: CATCommand? {
        CATCommand(wire: "TX;", replyPrefix: "TX")
    }

    public var readSMeter: CATCommand? {
        CATCommand(wire: "SM0;", replyPrefix: "SM0")
    }

    // MARK: - RF power (PC)

    public var readPower: CATCommand? {
        CATCommand(wire: "PC;", replyPrefix: "PC")
    }

    /// FT-891: 5–100 W. The FTX-1's limits are unconfirmed until hardware
    /// bring-up (references/yaesu-cat-ftx1.md); until then it shares the
    /// FT-891 range and the radio itself rejects what it can't do.
    public var powerRange: ClosedRange<Int>? { 5...100 }

    public func setPower(watts: Int) throws -> CATCommand {
        guard let range = powerRange, range.contains(watts) else {
            throw CATBridgeError.invalidArgument(
                "power \(watts) W outside \(powerRange.map(String.init(describing:)) ?? "supported") range")
        }
        return CATCommand(wire: String(format: "PC%03d;", watts),
                          replyPrefix: nil)
    }

    // MARK: - Settings (references/yaesu-cat-ft891.md command table)

    struct SettingSpec {
        let prefix: String // wire prefix incl. the fixed P1 digit, e.g. "AG0"
        let digits: Int
        let range: ClosedRange<Int>
    }

    static let settingSpecs: [RigSetting: SettingSpec] = [
        .afGain: SettingSpec(prefix: "AG0", digits: 3, range: 0...255),
        .rfGain: SettingSpec(prefix: "RG0", digits: 3, range: 0...255),
        .squelch: SettingSpec(prefix: "SQ0", digits: 3, range: 0...100),
        .micGain: SettingSpec(prefix: "MG", digits: 3, range: 0...100),
        .keyerSpeed: SettingSpec(prefix: "KS", digits: 3, range: 4...60),
        .breakIn: SettingSpec(prefix: "BI", digits: 1, range: 0...1),
        .noiseBlanker: SettingSpec(prefix: "NB0", digits: 1, range: 0...1),
        .noiseReduction: SettingSpec(prefix: "NR0", digits: 1, range: 0...1),
        // Preamp steps and width indices are model-dependent; the range is
        // the wire field's, and the radio answers `?;` for what it lacks.
        .preamp: SettingSpec(prefix: "PA0", digits: 1, range: 0...2),
        .attenuator: SettingSpec(prefix: "RA0", digits: 1, range: 0...1),
        .narrow: SettingSpec(prefix: "NA0", digits: 1, range: 0...1),
        .filterWidth: SettingSpec(prefix: "SH0", digits: 2, range: 0...21),
    ]

    public func readSetting(_ setting: RigSetting) -> CATCommand? {
        guard let spec = Self.settingSpecs[setting] else { return nil }
        return CATCommand(wire: "\(spec.prefix);", replyPrefix: spec.prefix)
    }

    public func setSetting(_ setting: RigSetting,
                           to value: Int) throws -> CATCommand {
        guard let spec = Self.settingSpecs[setting] else {
            throw CATBridgeError.unsupportedSetting(setting)
        }
        guard spec.range.contains(value) else {
            throw CATBridgeError.invalidArgument(
                "\(setting.rawValue) \(value) outside \(spec.range)")
        }
        let digits = String(format: "%0\(spec.digits)d", value)
        return CATCommand(wire: "\(spec.prefix)\(digits);", replyPrefix: nil)
    }

    public func settingRange(_ setting: RigSetting) -> ClosedRange<Int>? {
        Self.settingSpecs[setting]?.range
    }

    // MARK: - Menu (EX)

    /// FT-891 menu numbers are 4 digits (`EX0301;`). The FTX-1's numbering
    /// is unconfirmed until bring-up, so length is validated loosely.
    private func validatedMenuNumber(_ number: String) throws -> String {
        guard (3...6).contains(number.count),
              number.allSatisfy(\.isNumber) else {
            throw CATBridgeError.invalidArgument(
                "menu number must be 3-6 digits, got \"\(number)\"")
        }
        return number
    }

    public func readMenu(number: String) throws -> CATCommand {
        let number = try validatedMenuNumber(number)
        return CATCommand(wire: "EX\(number);", replyPrefix: "EX\(number)")
    }

    public func setMenu(number: String, value: String) throws -> CATCommand {
        let number = try validatedMenuNumber(number)
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else {
            throw CATBridgeError.invalidArgument(
                "menu value must be digits, got \"\(value)\"")
        }
        return CATCommand(wire: "EX\(number)\(value);", replyPrefix: nil)
    }

    public func setFrequency(_ frequency: Frequency) throws -> CATCommand {
        guard let digits = frequency.catDigits(width: 9) else {
            throw CATBridgeError.invalidArgument(
                "frequency \(frequency) exceeds 9-digit Yaesu field")
        }
        return CATCommand(wire: "FA\(digits);", replyPrefix: nil)
    }

    public func setMode(_ mode: OperatingMode) throws -> CATCommand {
        guard let code = Self.codeForMode[mode] else {
            throw CATBridgeError.unsupportedMode(mode)
        }
        return CATCommand(wire: "MD0\(code);", replyPrefix: nil)
    }

    public func keyerText(_ text: String) throws -> CATCommand {
        guard text.allSatisfy({ $0.isASCII && $0 != ";" }), !text.isEmpty
        else {
            throw CATBridgeError.invalidArgument("keyer text must be ASCII")
        }
        return CATCommand(wire: "KY\(text);", replyPrefix: nil,
                          isIdempotent: false)
    }

    public func parse(reply: String, to command: CATCommand) throws -> CATValue {
        try requireTerminated(reply)
        switch command.replyPrefix {
        case "ID":
            return .id(reply)
        case "FA":
            return .frequency(try parseFrequency(reply))
        case "MD0":
            return .mode(try parseMode(reply))
        case "TX":
            return .ptt(try parsePTT(reply))
        case "SM0":
            return .sMeter(try parseSMeter(reply))
        case "IF":
            return .info(try parseInfo(reply))
        case "PC":
            return .power(try parsePower(reply))
        case let prefix?:
            if prefix.hasPrefix("EX") {
                let number = String(prefix.dropFirst(2))
                return .menu(number: number,
                             value: try parseMenu(reply, number: number))
            }
            if let (setting, spec) = Self.settingSpecs.first(
                where: { $0.value.prefix == prefix }) {
                return .setting(setting,
                                try parseSetting(reply, spec: spec.prefix))
            }
            return .raw(reply)
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
        if frame.hasPrefix("MD0"), let m = try? parseMode(frame) {
            return .mode(m)
        }
        if frame.hasPrefix("PC"), let w = try? parsePower(frame) {
            return .power(w)
        }
        return nil
    }

    // MARK: - Field parsers

    private func parseFrequency(_ reply: String) throws -> Frequency {
        // FA + digits + ;. The field is nine digits on an FT-891; newer
        // radios in the family are documented with wider ones, so take
        // whatever digits are there rather than a fixed slice.
        guard reply.hasPrefix("FA"), reply.hasSuffix(";") else {
            throw CATBridgeError.malformedResponse(reply)
        }
        // Nine on an FT-891, documented wider on newer radios in the family.
        // Bounded rather than open-ended: a two-digit "FA01;" is a truncated
        // reply, not a 1 Hz VFO.
        let digits = reply.dropFirst(2).dropLast()
        guard (9...11).contains(digits.count), digits.allSatisfy(\.isNumber),
              let hz = UInt64(digits)
        else { throw CATBridgeError.malformedResponse(reply) }
        return Frequency(hz: hz)
    }

    private func parseMode(_ reply: String) throws -> OperatingMode {
        // MD0<code>;
        let chars = Array(reply)
        guard chars.count == 5, reply.hasPrefix("MD0"),
              let mode = Self.modeForCode[chars[3]]
        else { throw CATBridgeError.malformedResponse(reply) }
        return mode
    }

    private func parsePTT(_ reply: String) throws -> Bool {
        // TX0; = receive, TX1;/TX2; = transmit
        let chars = Array(reply)
        guard chars.count == 4, reply.hasPrefix("TX") else {
            throw CATBridgeError.malformedResponse(reply)
        }
        return chars[2] != "0"
    }

    private func parsePower(_ reply: String) throws -> Double {
        // PCnnn; — whole watts on Yaesu.
        let chars = Array(reply)
        guard chars.count == 6, reply.hasPrefix("PC"),
              let watts = Int(String(chars[2...4]))
        else { throw CATBridgeError.malformedResponse(reply) }
        return Double(watts)
    }

    private func parseSetting(_ reply: String, spec prefix: String)
        throws -> Int {
        // <prefix><digits>;
        guard reply.hasPrefix(prefix), reply.hasSuffix(";"),
              let value = Int(reply.dropFirst(prefix.count).dropLast())
        else { throw CATBridgeError.malformedResponse(reply) }
        return value
    }

    private func parseMenu(_ reply: String, number: String) throws -> String {
        // EX<number><value>;
        let prefix = "EX\(number)"
        let value = String(reply.dropFirst(prefix.count).dropLast())
        guard reply.hasPrefix(prefix), reply.hasSuffix(";"),
              !value.isEmpty, value.allSatisfy(\.isNumber)
        else { throw CATBridgeError.malformedResponse(reply) }
        return value
    }

    private func parseSMeter(_ reply: String) throws -> Int {
        // SM0nnn;
        let chars = Array(reply)
        guard chars.count == 7, reply.hasPrefix("SM0"),
              let value = Int(String(chars[3...5]))
        else { throw CATBridgeError.malformedResponse(reply) }
        return value
    }

    private func parseInfo(_ reply: String) throws -> RigInfo {
        // IF | field(3 or 5) | freq(9) | clar(±4) | rxclar | txclar | mode …
        //
        // The field between "IF" and the frequency is **three** characters
        // on an FT-891 and **five** on an FTX-1, so a fixed window reads
        // the wrong nine digits on one radio or the other — 14.074 MHz came
        // back as 760.140.740 on an FTX-1.
        //
        // Anchor on the clarifier's sign instead: it is the first `+` or
        // `-` in the reply and always sits immediately after the frequency,
        // whatever the leading field's width.
        let chars = Array(reply)
        guard reply.hasPrefix("IF"),
              let sign = chars.firstIndex(where: { $0 == "+" || $0 == "-" }),
              sign >= 11,
              let hz = UInt64(String(chars[(sign - 9)..<sign]))
        else { throw CATBridgeError.malformedResponse(reply) }
        // Mode sits a fixed distance past the sign: clarifier digits (4),
        // then RX-clar and TX-clar flags, then the mode code.
        let modeIndex = sign + 7
        let mode = chars.indices.contains(modeIndex)
            ? Self.modeForCode[chars[modeIndex]] : nil
        // Yaesu IF carries no TX flag; PTT is polled via TX; separately.
        return RigInfo(frequency: Frequency(hz: hz), mode: mode,
                       isTransmitting: nil)
    }
}
