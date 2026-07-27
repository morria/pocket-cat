// FT-891-specific value types for the command surface that CATBridgeKit
// leaves untyped. Wire formats per docs/ft891-cat-commands.md.

import CATBridgeCore

/// Antenna tuner state (`AC`). Starting a tune cycle transmits a carrier.
public enum TunerState: Int, Sendable, Equatable {
    case off = 0
    case on = 1
    case tuning = 2
}

/// `RM` meter selects.
public enum FT891Meter: Character, Sendable, CaseIterable {
    case panel = "0"     // whatever the front-panel meter shows
    case sMeter = "1"
    case txPanel = "2"   // the selected TX meter
    case comp = "3"
    case alc = "4"
    case power = "5"
    case swr = "6"
    case current = "7"   // final ID (amps)
}

/// `BS` band codes. There is no 5 MHz code (60 m is memory-only).
public enum FT891Band: String, Sendable, CaseIterable, Identifiable {
    case m160 = "00"
    case m80 = "01"
    case m40 = "03"
    case m30 = "04"
    case m20 = "05"
    case m17 = "06"
    case m15 = "07"
    case m12 = "08"
    case m10 = "09"
    case m6 = "10"
    case gen = "11"
    case mw = "12"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .m160: "160m"
        case .m80: "80m"
        case .m40: "40m"
        case .m30: "30m"
        case .m20: "20m"
        case .m17: "17m"
        case .m15: "15m"
        case .m12: "12m"
        case .m10: "10m"
        case .m6: "6m"
        case .gen: "GEN"
        case .mw: "MW"
        }
    }
}

/// `ST` split state.
public enum SplitState: Int, Sendable, Equatable {
    case off = 0
    case on = 1
    /// Split on with TX shifted 5 kHz up.
    case onPlus5k = 2
}

/// Operating modes the FT-891 actually supports (subset of CATBridgeKit's
/// `OperatingMode` — the radio has no C4FM/DATA-FM and rejects them).
public enum FT891Mode {
    public static let all: [OperatingMode] = [
        .lsb, .usb, .cw, .cwReverse, .am, .amNarrow, .fm, .fmNarrow,
        .dataLSB, .dataUSB, .rtty, .rttyReverse,
    ]

    /// Yaesu MD wire codes for the modes the FT-891 supports
    /// (docs/ft891-cat-commands.md §3.2; code "A"/"E"/"F" unused here).
    public static let codeForMode: [OperatingMode: Character] = [
        .lsb: "1", .usb: "2", .cw: "3", .fm: "4", .am: "5",
        .rtty: "6", .cwReverse: "7", .dataLSB: "8", .rttyReverse: "9",
        .fmNarrow: "B", .dataUSB: "C", .amNarrow: "D",
    ]

    public static let modeForCode: [Character: OperatingMode] =
        Dictionary(uniqueKeysWithValues: codeForMode.map { ($1, $0) })

    public static func title(_ mode: OperatingMode) -> String {
        switch mode {
        case .lsb: "LSB"
        case .usb: "USB"
        case .cw: "CW"
        case .cwReverse: "CW-R"
        case .am: "AM"
        case .amNarrow: "AM-N"
        case .fm: "FM"
        case .fmNarrow: "FM-N"
        case .rtty: "RTTY"
        case .rttyReverse: "RTTY-R"
        case .dataLSB: "DATA-L"
        case .dataUSB: "DATA-U"
        case .dataFM: "DATA-FM"
        case .dataFMNarrow: "DATA-FM-N"
        case .c4fm: "C4FM"
        }
    }
}

public enum FT891Error: Error, Equatable {
    case malformedReply(command: String, reply: String)
}
