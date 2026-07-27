// The semantic layer over the FT-891 menu system that CATBridgeKit
// deliberately doesn't own: names, descriptions, value typing, and the
// engineering-value ↔ wire-digit codecs. Source of truth for the item
// table is docs/ft891-menus.md (checked by MenuCatalogDocTests).

import Foundation

/// The radio's 18 menu groups, in front-panel order.
public enum MenuGroup: Int, CaseIterable, Sendable, Identifiable {
    case agc = 1, display, dvs, keyer, general
    case modeAM, modeCW, modeDATA, modeFM, modeRTTY, modeSSB
    case rxDSP, scope, tuning, txAudio, txGeneral, reset, version

    public var id: Int { rawValue }

    /// Two-digit group prefix as it appears in menu numbers ("05").
    public var numberPrefix: String { String(format: "%02d", rawValue) }

    /// Friendly section title for the Settings screen.
    public var title: String {
        switch self {
        case .agc: "AGC"
        case .display: "Display"
        case .dvs: "Voice Memory (DVS)"
        case .keyer: "CW Keyer"
        case .general: "General"
        case .modeAM: "AM Mode"
        case .modeCW: "CW Mode"
        case .modeDATA: "Data Mode"
        case .modeFM: "FM Mode"
        case .modeRTTY: "RTTY Mode"
        case .modeSSB: "SSB Mode"
        case .rxDSP: "Receive DSP"
        case .scope: "Band Scope"
        case .tuning: "Tuning Steps"
        case .txAudio: "Transmit Audio"
        case .txGeneral: "Transmit"
        case .reset: "Reset"
        case .version: "Firmware Versions"
        }
    }
}

/// How a menu item's value behaves. All values are carried as `Int` in
/// engineering units; the kind defines validation, wire coding, and labels.
public enum MenuValueKind: Sendable, Equatable {
    /// 0/1 off/on — renders as a Toggle.
    case toggle
    /// Index-coded choice list; value = index into `labels`.
    case options([String])
    /// Plain number stored on the wire as its own value (zero-padded).
    case number(ClosedRange<Int>, step: Int = 1, unit: String? = nil)
    /// Number with a mandatory `+`/`-` sign on the wire (zero may be
    /// `+0…`/`-0…`; we emit `+`).
    case signedNumber(ClosedRange<Int>, step: Int = 1, unit: String? = nil)

    public var range: ClosedRange<Int> {
        switch self {
        case .toggle: 0...1
        case let .options(labels): 0...(labels.count - 1)
        case let .number(range, _, _), let .signedNumber(range, _, _): range
        }
    }

    public var step: Int {
        switch self {
        case let .number(_, step, _), let .signedNumber(_, step, _): step
        default: 1
        }
    }

    public var unit: String? {
        switch self {
        case let .number(_, _, unit), let .signedNumber(_, _, unit): unit
        default: nil
        }
    }
}

public struct MenuItem: Sendable, Identifiable, Equatable {
    /// Front-panel number, e.g. `"05-06"`.
    public let id: String
    public let group: MenuGroup
    /// Name as printed in the Yaesu manual, e.g. `"CAT RATE"`.
    public let officialName: String
    /// Plain-English name for the Settings row headline.
    public let friendlyName: String
    /// One-sentence description used as row subtext.
    public let summary: String
    public let kind: MenuValueKind
    /// Wire digit count of P2, excluding any sign character.
    public let digits: Int
    /// Factory default in engineering units.
    public let defaultValue: Int
    /// False for the read-only 18-xx VERSION items.
    public let isWritable: Bool
    /// True for 17-01 RESET: writing performs a radio reset. Excluded from
    /// profiles and rendered as an action, not a setting.
    public let isAction: Bool

    public init(id: String, group: MenuGroup, officialName: String,
                friendlyName: String, summary: String, kind: MenuValueKind,
                digits: Int, defaultValue: Int, isWritable: Bool = true,
                isAction: Bool = false) {
        self.id = id
        self.group = group
        self.officialName = officialName
        self.friendlyName = friendlyName
        self.summary = summary
        self.kind = kind
        self.digits = digits
        self.defaultValue = defaultValue
        self.isWritable = isWritable
        self.isAction = isAction
    }

    /// CAT menu number: `"05-06"` → `"0506"`.
    public var exNumber: String { id.replacingOccurrences(of: "-", with: "") }

    /// True when the wire value carries a mandatory sign — these items
    /// cannot pass CATBridgeKit's digits-only menu API and go via raw CAT.
    public var isSigned: Bool {
        if case .signedNumber = kind { return true }
        return false
    }

    // MARK: - Codec

    public enum CodecError: Error, Equatable {
        case outOfRange(item: String, value: Int)
        case malformed(item: String, raw: String)
    }

    /// Engineering value → wire digit string (P2), e.g. 300 → `"0300"`,
    /// -5 → `"-05"`.
    public func encode(_ value: Int) throws -> String {
        guard kind.range.contains(value) else {
            throw CodecError.outOfRange(item: id, value: value)
        }
        let magnitude = String(format: "%0\(digits)d", abs(value))
        guard magnitude.count == digits else {
            throw CodecError.outOfRange(item: id, value: value)
        }
        if isSigned { return (value < 0 ? "-" : "+") + magnitude }
        return magnitude
    }

    /// Wire digit string → engineering value. Tolerant of `+00`/`-00` and
    /// of a different zero-padded width than documented — the CAT book's
    /// digit columns are not always what the radio actually sends (verified
    /// on hardware: EX1302 answers 2 digits where the book says 1).
    public func decode(_ raw: String) throws -> Int {
        var text = Substring(raw)
        var negative = false
        if isSigned {
            switch text.first {
            case "+": text = text.dropFirst()
            case "-": negative = true; text = text.dropFirst()
            default: throw CodecError.malformed(item: id, raw: raw)
            }
        }
        guard !text.isEmpty, text.allSatisfy(\.isNumber),
              let magnitude = Int(text) else {
            throw CodecError.malformed(item: id, raw: raw)
        }
        let value = negative ? -magnitude : magnitude
        guard kind.range.contains(value) else {
            throw CodecError.malformed(item: id, raw: raw)
        }
        return value
    }

    /// Display string for a value ("700 ms", "38400 bps", "ON").
    public func label(for value: Int) -> String {
        switch kind {
        case .toggle:
            return value == 0 ? "Off" : "On"
        case let .options(labels):
            return labels.indices.contains(value) ? labels[value] : "\(value)"
        case let .number(_, _, unit), let .signedNumber(_, _, unit):
            let sign = (isSigned && value > 0) ? "+" : ""
            return unit.map { "\(sign)\(value) \($0)" } ?? "\(sign)\(value)"
        }
    }
}

/// Shared index-coded encodings used across the MODE groups
/// (docs/ft891-menus.md "Shared filter encodings").
public enum SharedEncoding {
    /// `00` = OFF; `01`–`19` = 100–1000 Hz in 50 Hz steps.
    public static let lcut = MenuValueKind.options(
        ["OFF"] + stride(from: 100, through: 1000, by: 50).map { "\($0) Hz" })
    /// `00` = OFF; `01`–`67` = 700–4000 Hz in 50 Hz steps.
    public static let hcut = MenuValueKind.options(
        ["OFF"] + stride(from: 700, through: 4000, by: 50).map { "\($0) Hz" })
    /// `0` = 6 dB/oct, `1` = 18 dB/oct.
    public static let slope = MenuValueKind.options(["6 dB/oct", "18 dB/oct"])
    /// `0` = front MIC jack, `1` = rear RTTY/DATA jack.
    public static let micSelect = MenuValueKind.options(["MIC", "REAR"])
    /// `0` = DAKY, `1` = RTS, `2` = DTR.
    public static let pttSelect = MenuValueKind.options(["DAKY", "RTS", "DTR"])
    /// 3-digit 0–100 level.
    public static let level100 = MenuValueKind.number(0...100)
}
