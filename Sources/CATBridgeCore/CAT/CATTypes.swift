// Shared CAT-layer value types.

/// Operating modes across the supported radios. Dialects map these to their
/// wire codes; a dialect throws `.unsupportedCapability`-style errors for
/// modes the radio lacks.
public enum OperatingMode: Sendable, Equatable, Hashable, CaseIterable {
    case lsb
    case usb
    case cw
    case cwReverse
    case fm
    case fmNarrow
    case am
    case amNarrow
    case rtty
    case rttyReverse
    case dataLSB
    case dataUSB
    case dataFM
    case dataFMNarrow
    case c4fm
}

/// What a given radio can do; apps query instead of guessing
/// (docs/implementation.md §4 point 5).
public struct RadioCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let frequencyControl = RadioCapabilities(rawValue: 1 << 0)
    public static let modeControl = RadioCapabilities(rawValue: 1 << 1)
    public static let ptt = RadioCapabilities(rawValue: 1 << 2)
    public static let sMeter = RadioCapabilities(rawValue: 1 << 3)
    public static let keyerText = RadioCapabilities(rawValue: 1 << 4)
    public static let rfPowerControl = RadioCapabilities(rawValue: 1 << 5)
    /// The radio can push state changes unsolicited (Yaesu Auto-Information).
    public static let autoInformation = RadioCapabilities(rawValue: 1 << 6)
}

/// The concrete radio model driving dialect selection and capabilities.
public enum RadioModel: Sendable, Equatable {
    case ft891
    case ftx1
    case qmx
    case generic(String)
}

/// One encodable CAT command with its reply expectation and retry policy.
public struct CATCommand: Sendable, Equatable {
    /// Full wire text including the trailing `;`.
    public let wire: String
    /// Expected reply prefix (e.g. `"FA"`); nil for set commands that the
    /// radio answers with silence.
    public let replyPrefix: String?
    /// Idempotent commands may be retried once on timeout or `?;`-busy.
    public let isIdempotent: Bool
    /// True for the dialect's PTT-on command — gated by the failsafe interlock.
    public let isPTTOn: Bool

    public init(wire: String, replyPrefix: String? = nil,
                isIdempotent: Bool = true, isPTTOn: Bool = false) {
        self.wire = wire
        self.replyPrefix = replyPrefix
        self.isIdempotent = isIdempotent
        self.isPTTOn = isPTTOn
    }
}

/// Parsed composite state from `IF;` (field availability differs by dialect:
/// Yaesu's IF has no TX flag; Kenwood's does).
public struct RigInfo: Sendable, Equatable {
    public let frequency: Frequency
    public let mode: OperatingMode?
    public let isTransmitting: Bool?

    public init(frequency: Frequency, mode: OperatingMode?,
                isTransmitting: Bool?) {
        self.frequency = frequency
        self.mode = mode
        self.isTransmitting = isTransmitting
    }
}

/// A parsed CAT reply or unsolicited frame.
public enum CATValue: Sendable, Equatable {
    case id(String)
    case frequency(Frequency)
    case mode(OperatingMode)
    case ptt(Bool)
    case sMeter(Int)
    case info(RigInfo)
    case raw(String)
}
