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
         .rfPowerControl]
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
        return nil
    }

    // MARK: - Field parsers

    private func parseFrequency(_ reply: String) throws -> Frequency {
        // FA + 9 digits + ;
        let chars = Array(reply)
        guard chars.count == 12, reply.hasPrefix("FA"),
              let hz = UInt64(String(chars[2...10]))
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

    private func parseSMeter(_ reply: String) throws -> Int {
        // SM0nnn;
        let chars = Array(reply)
        guard chars.count == 7, reply.hasPrefix("SM0"),
              let value = Int(String(chars[3...5]))
        else { throw CATBridgeError.malformedResponse(reply) }
        return value
    }

    private func parseInfo(_ reply: String) throws -> RigInfo {
        // IF | mem(3) | freq(9) | clar(5) | rxclar(1) | txclar(1) | mode(1) …
        let chars = Array(reply)
        guard chars.count >= 23, reply.hasPrefix("IF"),
              let hz = UInt64(String(chars[5...13]))
        else { throw CATBridgeError.malformedResponse(reply) }
        let mode = Self.modeForCode[chars[21]]
        // Yaesu IF carries no TX flag; PTT is polled via TX; separately.
        return RigInfo(frequency: Frequency(hz: hz), mode: mode,
                       isTransmitting: nil)
    }
}
