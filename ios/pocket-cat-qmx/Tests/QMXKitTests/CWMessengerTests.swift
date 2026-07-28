// CW messaging: text rules for the wire, bubble grouping, and a full
// round trip through the simulator (KY out, TB back).

import CATBridgeCore
import Foundation
import Testing
@testable import QMXKit

@Suite("CW messenger")
struct CWMessengerTests {
    func makeReadySession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    // MARK: - Text rules

    @Test func normalizeUpperCasesAndDropsUnsendable() {
        let (text, dropped) = CWText.normalize("cq de m0abc \u{1F4FB}")
        #expect(text == "CQ DE M0ABC")
        #expect(dropped == ["\u{1F4FB}"])
    }

    @Test func normalizeCollapsesWhitespaceAndTrims() {
        let (text, dropped) = CWText.normalize("  cq   cq \n de  ")
        #expect(text == "CQ CQ DE")
        #expect(dropped.isEmpty)
    }

    @Test func semicolonNeverSurvivesNormalization() {
        // A bare ';' would terminate the CAT frame early.
        let (text, dropped) = CWText.normalize("ab;cd")
        #expect(text == "ABCD")
        #expect(dropped == [";"])
    }

    @Test func chunksSplitOnWordBoundariesWithinLimit() {
        let chunks = CWText.chunks("CQ CQ CQ DE M0ABC M0ABC K", limit: 12)
        #expect(chunks.allSatisfy { $0.count <= 12 })
        #expect(chunks.joined(separator: " ") == "CQ CQ CQ DE M0ABC M0ABC K")
    }

    @Test func chunksHardSplitOverlongWords() {
        let chunks = CWText.chunks(String(repeating: "A", count: 30), limit: 12)
        #expect(chunks.count == 3)
        #expect(chunks.map(\.count) == [12, 12, 6])
    }

    // MARK: - Bubble grouping

    @Test @MainActor func decodedFragmentsCoalesceWithinWindow() {
        let messenger = CWMessenger()
        let start = Date()
        messenger.ingest("CQ ", at: start)
        messenger.ingest("DE M0ABC", at: start.addingTimeInterval(1))
        #expect(messenger.messages.count == 1)
        #expect(messenger.messages[0].text == "CQ DE M0ABC")
        #expect(messenger.messages[0].direction == .received)
    }

    @Test @MainActor func aLongGapStartsANewBubble() {
        let messenger = CWMessenger()
        let start = Date()
        messenger.ingest("CQ", at: start)
        messenger.ingest("K", at: start.addingTimeInterval(60))
        #expect(messenger.messages.count == 2)
    }

    @Test @MainActor func blankDecodesAreIgnored() {
        let messenger = CWMessenger()
        messenger.ingest("   ")
        messenger.ingest("")
        #expect(messenger.messages.isEmpty)
    }

    // MARK: - Sending

    @Test @MainActor func sendWithNoSessionFailsTheBubbleNotSilently() async {
        let messenger = CWMessenger()
        await messenger.send("CQ")
        #expect(messenger.messages.count == 1)
        #expect(messenger.messages[0].direction == .sent)
        #expect(messenger.messages[0].state == .failed("Not connected"))
    }

    @Test @MainActor func sendKeysTheRadioAndMarksTheBubble() async throws {
        let (session, transport) = try await makeReadySession()
        let messenger = CWMessenger(session: session)

        await messenger.send("cq de m0abc")

        #expect(messenger.messages.count == 1)
        #expect(messenger.messages[0].text == "CQ DE M0ABC")
        #expect(messenger.messages[0].state == .keyed)
        // The simulator feeds keyed text back through its decoder.
        let buffered = await transport.rigState.decodeBuffer
        #expect(buffered.contains("CQ DE M0ABC"))
        await session.disconnect()
    }

    @Test @MainActor func unsupportedCharactersRaiseANotice() async throws {
        let (session, _) = try await makeReadySession()
        let messenger = CWMessenger(session: session)
        await messenger.send("hi \u{1F4FB}")
        #expect(messenger.notice != nil)
        #expect(messenger.messages[0].text == "HI")
        await session.disconnect()
    }

    @Test @MainActor func emptyDraftSendsNothing() async {
        let messenger = CWMessenger()
        await messenger.send("   ")
        #expect(messenger.messages.isEmpty)
    }

    // MARK: - Round trip

    @Test @MainActor func decoderPollSurfacesReceivedText() async throws {
        let (session, transport) = try await makeReadySession()
        let messenger = CWMessenger(session: session)

        await transport.setRig { $0.decodeBuffer = "CQ DE G0XYZ K" }
        await messenger.pollOnce()

        #expect(messenger.messages.count == 1)
        #expect(messenger.messages[0].direction == .received)
        #expect(messenger.messages[0].text == "CQ DE G0XYZ K")
        // Draining is destructive: the radio hands each fragment over once.
        await messenger.pollOnce()
        #expect(messenger.messages.count == 1)
        await session.disconnect()
    }

    @Test @MainActor func longSendIsChunkedButReadsBackWhole() async throws {
        let (session, transport) = try await makeReadySession()
        let messenger = CWMessenger(session: session)

        let text = "CQ CQ CQ DE M0ABC M0ABC PSE K"
        await messenger.send(text)

        #expect(messenger.messages[0].state == .keyed)
        let buffered = await transport.rigState.decodeBuffer
        // Chunk boundaries land on spaces, so the words survive intact.
        for word in text.split(separator: " ") {
            #expect(buffered.contains(word))
        }
        await session.disconnect()
    }

    @Test @MainActor func retryResendsAFailedBubble() async throws {
        let messenger = CWMessenger()
        await messenger.send("CQ")
        #expect(messenger.messages[0].state == .failed("Not connected"))

        let (session, _) = try await makeReadySession()
        messenger.session = session
        await messenger.retry(messenger.messages[0].id)

        #expect(messenger.messages.count == 1)
        #expect(messenger.messages[0].state == .keyed)
        await session.disconnect()
    }
}
