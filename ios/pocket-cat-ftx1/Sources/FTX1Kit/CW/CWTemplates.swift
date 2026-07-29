// One-tap operating messages with {TOKEN} placeholders, and callsign
// spotting in decoded copy.
//
// Templates fill the compose field — they never send by themselves. A
// station's own details come from AppSettings, so a callsign is typed once
// and reused by CW, WSPR and anything else that needs it.

import Foundation

public struct CWTemplate: Identifiable, Sendable, Hashable {
    public let label: String
    public let text: String
    public var id: String { label }

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }

    /// The standard exchange, in the order a QSO tends to need it.
    public static let defaults: [CWTemplate] = [
        CWTemplate(label: "CQ", text: "CQ CQ CQ DE {CALL} {CALL} K"),
        CWTemplate(label: "Reply", text: "{THEIRCALL} DE {CALL} {CALL} K"),
        CWTemplate(label: "RST", text: "UR RST 599 599"),
        CWTemplate(label: "Name", text: "OP {NAME} {NAME}"),
        CWTemplate(label: "QTH", text: "QTH {QTH} {QTH}"),
        CWTemplate(label: "Grid", text: "GRID {GRID} {GRID}"),
        CWTemplate(label: "73", text: "73 TU DE {CALL} SK"),
    ]

    /// True when the template needs a station to address and so has no
    /// meaning until one has been heard.
    public var needsTheirCall: Bool {
        text.range(of: "{THEIRCALL}", options: .caseInsensitive) != nil
    }
}

public struct ExpandedTemplate: Sendable, Equatable {
    public let text: String
    /// Tokens whose backing field is empty. Point the operator at Settings
    /// rather than key a message with a hole in it.
    public let missing: [String]
}

/// The operator's own details, as templates refer to them.
public struct StationIdentity: Sendable, Equatable {
    public var callsign: String
    public var name: String
    public var qth: String
    public var grid: String

    public init(callsign: String = "", name: String = "", qth: String = "",
                grid: String = "") {
        self.callsign = callsign
        self.name = name
        self.qth = qth
        self.grid = grid
    }

    public func expand(_ template: String,
                       theirCall: String? = nil) -> ExpandedTemplate {
        var text = template
        var missing: [String] = []
        let tokens = [("CALL", callsign), ("NAME", name), ("QTH", qth),
                      ("GRID", grid), ("THEIRCALL", theirCall ?? "")]
        for (token, value) in tokens {
            let pattern = "{\(token)}"
            guard text.range(of: pattern, options: .caseInsensitive) != nil
            else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { missing.append(token) }
            while let range = text.range(of: pattern,
                                         options: .caseInsensitive) {
                text.replaceSubrange(range, with: trimmed)
            }
        }
        return ExpandedTemplate(text: text.uppercased(), missing: missing)
    }

    /// "your callsign, your grid square" — for a notice the operator can act on.
    public static func describe(_ tokens: [String]) -> String {
        tokens.map { token in
            switch token {
            case "CALL": "your callsign"
            case "NAME": "your name"
            case "QTH": "your location"
            case "GRID": "your grid square"
            case "THEIRCALL": "a station to reply to"
            default: token.lowercased()
            }
        }.joined(separator: ", ")
    }
}

public enum CallsignSpotter {
    /// Callsigns in decoded copy. Deliberately conservative: a decoder
    /// makes noise, and a chip that tunes you at a hallucinated station is
    /// worse than no chip.
    ///
    /// Requires the amateur shape — a prefix with a digit, then a suffix —
    /// with an optional `/P`-style appendage.
    public static func callsigns(in text: String) -> [String] {
        let pattern = "\\b[A-Z0-9]{1,3}[0-9][A-Z]{1,4}(?:/[A-Z0-9]{1,3})?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..., in: upper)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: upper, range: range) {
            guard let found = Range(match.range, in: upper) else { continue }
            let call = String(upper[found])
            // "599" and friends match nothing here, but a bare signal
            // report or serial could sneak through a sloppier pattern.
            guard call.contains(where: \.isLetter),
                  seen.insert(call).inserted else { continue }
            out.append(call)
        }
        return out
    }

    /// Most recently heard first, excluding the operator's own call.
    public static func recentCallsigns(in messages: [String],
                                       excluding mine: String,
                                       limit: Int = 3) -> [String] {
        let mine = mine.uppercased().trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        var out: [String] = []
        for message in messages.reversed() {
            for call in callsigns(in: message) where call != mine {
                guard seen.insert(call).inserted else { continue }
                out.append(call)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
