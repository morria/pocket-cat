// What the keyer can render, and how a message is split to fit one `KY`.
//
// Lifted from the QMX app: the rules are the radio-independent half of
// sending CW, and the two apps must agree about what is sendable.

import Foundation

/// Text rules for the wire: what the keyer can render, and how long a
/// single `KY` message may be.
public enum CWText {
    /// Characters International Morse defines and the QMX keyer renders.
    /// `;` is excluded by construction — it terminates every CAT frame.
    public static let allowed = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,?'!/()&:+-=@\"")

    /// Conservative per-`KY` payload. The QMX CAT manual documents two
    /// TS-480-compatible `KY` formats without pinning a maximum here, so
    /// we chunk at the classic TS-480 message length; over-chunking costs
    /// nothing but an extra frame.
    public static let chunkLimit = 24

    /// Upper-cases, collapses runs of whitespace, and drops anything the
    /// keyer cannot render. Returns what survived and what was removed.
    public static func normalize(_ raw: String)
        -> (text: String, dropped: Set<Character>) {
        let upper = raw.uppercased()
        var dropped: Set<Character> = []
        var kept = ""
        var lastWasSpace = true // also trims the leading space
        for character in upper {
            let isSpace = character == " " || character.isWhitespace
            if isSpace {
                if !lastWasSpace { kept.append(" ") }
                lastWasSpace = true
                continue
            }
            if allowed.contains(character) {
                kept.append(character)
                lastWasSpace = false
            } else {
                dropped.insert(character)
            }
        }
        while kept.hasSuffix(" ") { kept.removeLast() }
        return (kept, dropped)
    }

    /// Splits at word boundaries so each piece fits one `KY`. Words longer
    /// than the limit are hard-split rather than dropped.
    public static func chunks(_ text: String,
                              limit: Int = chunkLimit) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(word)
            while word.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(String(word.prefix(limit)))
                word = String(word.dropFirst(limit))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                chunks.append(current)
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
