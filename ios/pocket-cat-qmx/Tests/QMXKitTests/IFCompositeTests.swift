// The TS-480 `IF` composite is positional, and the library reads the TX
// flag and mode at fixed offsets. The simulator emitted a four-character
// flag block where the format has five, so every field after it sat one
// place early: the parser read the mode digit as the TX flag, reported
// "receiving" on the first poll after keying, and the app dropped out of
// transmit while PTT was still held.
//
// These pin the offsets the parser actually uses.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("IF composite")
struct IFCompositeTests {
    /// `KenwoodDialect.parseInfo` reads `chars[28]` for TX and `chars[29]`
    /// for mode, counting from the "I" of "IF".
    @Test func txFlagAndModeLandWhereTheParserLooks() {
        var rig = QMXSimRig()
        rig.transmitting = true
        rig.modeCode = "6"
        let reply = rig.respond(to: "IF;")!
        let chars = Array(reply)

        #expect(chars.count >= 31)
        #expect(chars[28] == "1", "TX flag is not at the parsed offset")
        #expect(chars[29] == "6", "mode is not at the parsed offset")
    }

    @Test func receivingReadsAsReceiving() {
        var rig = QMXSimRig()
        rig.transmitting = false
        rig.modeCode = "3"
        let chars = Array(rig.respond(to: "IF;")!)
        #expect(chars[28] == "0")
        #expect(chars[29] == "3")
    }

    /// The flag block is five characters: RIT-on, XIT, bank, channel(2).
    @Test func theFlagBlockIsFiveCharacters() {
        var rig = QMXSimRig()
        rig.ritOn = true
        let chars = Array(rig.respond(to: "IF;")!)
        #expect(chars[23] == "1")                       // RIT on
        #expect(String(chars[24...27]) == "0000")       // xit, bank, ch
    }

    /// The RIT field must stay where `readRITOffset` reads it.
    @Test func ritOffsetSurvivesTheLayout() async throws {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        await transport.setRig { $0.ritOffset = -250 }
        #expect(try await session.readRITOffset() == -250)
        await session.disconnect()
    }

    /// Keying must survive a status poll — this is the flash the operator
    /// saw: red for an instant, then back to blue with PTT still held.
    @Test func keyingSurvivesAnIFPoll() async throws {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()

        try await session.transmit()
        #expect(await session.state.isTransmitting)

        _ = try await session.rawCommand("IF;", expectsReply: true,
                                         isIdempotent: true)
        #expect(await session.state.isTransmitting,
                "an IF poll cleared the transmit state")

        try await session.receive()
        #expect(await session.state.isTransmitting == false)
        await session.disconnect()
    }
}
