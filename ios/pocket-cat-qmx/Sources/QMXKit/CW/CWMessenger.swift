// A CW conversation carried entirely over CAT: the QMX's own decoder
// (`TB`) supplies the incoming side and buffered message keying (`KY`)
// sends the outgoing side. No audio path and no DSP are involved — see
// esp32s3/docs/references/qmx-cat.md lines 52 and 66.
//
// `KY` is *buffered message* keying, not real-time element timing, so BLE
// latency does not affect what goes out on the air (the system's
// timing-accurate-keying non-goal, esp32s3/docs/implementation.md §1).

import CATBridgeCore
import Foundation
import Observation

/// One bubble in the transcript.
public struct CWMessage: Identifiable, Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case sent
        case received
    }

    /// Outgoing lifecycle. `keyed` means the radio accepted the text into
    /// its keyer buffer — the air time follows at the current WPM, which
    /// CAT gives us no completion signal for.
    public enum DeliveryState: Sendable, Equatable {
        case sending
        case keyed
        case failed(String)
    }

    public let id: UUID
    public internal(set) var text: String
    public let direction: Direction
    public let date: Date
    public internal(set) var state: DeliveryState

    init(id: UUID = UUID(), text: String, direction: Direction,
         date: Date = Date(), state: DeliveryState = .keyed) {
        self.id = id
        self.text = text
        self.direction = direction
        self.date = date
        self.state = state
    }
}

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

/// The transcript: polls the radio's decoder, sends typed text as CW, and
/// groups both into iMessage-style bubbles.
@MainActor
@Observable
public final class CWMessenger {
    public private(set) var messages: [CWMessage] = []
    public private(set) var isListening = false
    /// Set when typed text contained characters Morse cannot carry.
    public var notice: String?

    /// Decoded fragments arriving within this window of the previous one
    /// join the same bubble; a longer gap starts a new one.
    public var coalesceWindow: TimeInterval = 8
    public var pollInterval: Duration = .milliseconds(500)

    /// The live session. Nil while disconnected — sending then fails the
    /// message rather than silently dropping it.
    public var session: TransceiverSession?

    private var pollTask: Task<Void, Never>?
    private var lastReceivedAt: Date?

    public init(session: TransceiverSession? = nil) {
        self.session = session
    }

    // The poll task holds `self` weakly and returns once the messenger is
    // gone, so there is nothing to tear down in `deinit`.

    // MARK: - Listening

    public func startListening() {
        guard pollTask == nil else { return }
        isListening = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopListening() {
        pollTask?.cancel()
        pollTask = nil
        isListening = false
    }

    /// One drain of the radio's 40-char decode buffer. Errors are ignored:
    /// a dropped poll costs one fragment and the next one recovers.
    func pollOnce() async {
        guard let session else { return }
        guard let text = try? await session.readDecodedCW(), !text.isEmpty
        else { return }
        ingest(text)
    }

    /// Appends decoded text, joining the previous received bubble when it
    /// is recent enough.
    func ingest(_ fragment: String, at date: Date = Date()) {
        let text = fragment.uppercased()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        defer { lastReceivedAt = date }

        // Fragments join verbatim: the decoder hands over a byte stream and
        // may split mid-word, so the inter-fragment spacing is the radio's
        // to decide, not ours. Only a new bubble drops leading blanks.
        if let last = messages.indices.last,
           messages[last].direction == .received,
           let previous = lastReceivedAt,
           date.timeIntervalSince(previous) <= coalesceWindow {
            messages[last].text += text
            return
        }
        messages.append(CWMessage(text: String(text.drop(while: \.isWhitespace)),
                                  direction: .received, date: date))
    }

    // MARK: - Sending

    /// Normalizes, appends the bubble immediately, then keys it out in
    /// `KY`-sized chunks. The bubble carries its own failure state so the
    /// transcript shows what did and didn't make it to the radio.
    public func send(_ raw: String) async {
        let (text, dropped) = CWText.normalize(raw)
        if !dropped.isEmpty {
            let list = dropped.sorted().map(String.init).joined(separator: " ")
            notice = "Morse can't carry \(list) — removed."
        }
        guard !text.isEmpty else { return }

        let message = CWMessage(text: text, direction: .sent, state: .sending)
        messages.append(message)

        guard let session else {
            update(message.id) { $0.state = .failed("Not connected") }
            return
        }
        do {
            for chunk in CWText.chunks(text) {
                try await session.send(keyerText: chunk)
            }
            update(message.id) { $0.state = .keyed }
        } catch {
            update(message.id) { $0.state = .failed(Self.reason(for: error)) }
        }
    }

    /// Re-sends a failed bubble in place.
    public func retry(_ id: CWMessage.ID) async {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .failed = messages[index].state else { return }
        let text = messages[index].text
        messages.remove(at: index)
        await send(text)
    }

    public func clear() {
        messages.removeAll()
        lastReceivedAt = nil
    }

    // MARK: - Internals

    /// Mutates by identity — the transcript can grow from the decoder
    /// while a send is in flight, so indices captured before an `await`
    /// are not safe.
    private func update(_ id: CWMessage.ID,
                        _ body: (inout CWMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&messages[index])
    }

    private static func reason(for error: Error) -> String {
        switch error as? CATBridgeError {
        case .connectionLost, .bondInvalidated: "Link lost"
        case .usbRadioDisconnected: "Radio unplugged"
        case .unsupportedCapability: "Radio can't key from CAT"
        case .timedOut, .radioNotResponding: "No answer from the radio"
        case .notReady: "Not connected"
        case .pttInterlock(let why): why
        default: "Send failed"
        }
    }
}
