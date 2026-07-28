// WSPR encoding and beacon behaviour.
//
// No on-air reference vector is available here, so correctness is pinned
// three ways: the packers are proved by round trip, the frame is proved by
// the protocol's own structural invariants (length, symbol range, and the
// sync bit surviving as the LSB of every symbol), and the beacon is driven
// end-to-end against the simulator with a compressed symbol period.

import CATBridgeCore
import Foundation
import Testing
@testable import QMXKit

@Suite("WSPR encoder")
struct WSPREncoderTests {
    @Test func syncVectorIsTheProtocolConstant() {
        #expect(WSPREncoder.syncVector.count == 162)
        // Cross-checked against two independent published copies.
        #expect(WSPREncoder.syncVector.reduce(0, { $0 + Int($1) }) == 63)
        #expect(WSPREncoder.syncVector.allSatisfy { $0 <= 1 })
    }

    @Test func frameIsOneHundredSixtyTwoSymbolsInRange() throws {
        let symbols = try WSPREncoder.symbols(callsign: "K1ABC",
                                              grid: "FN42", powerDBm: 37)
        #expect(symbols.count == 162)
        #expect(symbols.allSatisfy { $0 <= 3 })
    }

    /// symbol = sync + 2 × data, so the sync bit must survive as the LSB of
    /// every symbol. This is what a decoder locks onto.
    @Test func everySymbolCarriesItsSyncBit() throws {
        let symbols = try WSPREncoder.symbols(callsign: "M0ABC",
                                              grid: "IO91", powerDBm: 23)
        for (index, symbol) in symbols.enumerated() {
            #expect(symbol % 2 == WSPREncoder.syncVector[index])
        }
    }

    @Test func differentMessagesProduceDifferentFrames() throws {
        let a = try WSPREncoder.symbols(callsign: "K1ABC", grid: "FN42",
                                        powerDBm: 37)
        let b = try WSPREncoder.symbols(callsign: "K1ABC", grid: "FN43",
                                        powerDBm: 37)
        #expect(a != b)
    }

    // MARK: - Packing

    @Test(arguments: ["K1ABC", "M0ABC", "G0XYZ", "GM4ABC", "W1AW", "VP8ABC"])
    func callsignRoundTrips(_ call: String) throws {
        let packed = try WSPREncoder.packCallsign(call)
        let expected = try WSPREncoder.normalizeCallsign(call)
        #expect(WSPREncoder.unpack(callsign: packed) == expected)
        #expect(packed < 1 << 28)
    }

    @Test func shortCallsignsShiftRightSoTheDigitLandsThird() throws {
        #expect(try WSPREncoder.normalizeCallsign("K1ABC") == " K1ABC")
        #expect(try WSPREncoder.normalizeCallsign("GM4ABC") == "GM4ABC")
        #expect(try WSPREncoder.normalizeCallsign("W1AW") == " W1AW ")
    }

    @Test(arguments: [("IO91", 23), ("FN42", 37), ("AA00", 0),
                      ("RR99", 60), ("JO65", 10)])
    func gridAndPowerRoundTrip(_ input: (grid: String, power: Int)) throws {
        let packed = try WSPREncoder.packGridAndPower(grid: input.grid,
                                                      powerDBm: input.power)
        let (grid, power) = WSPREncoder.unpack(gridPower: packed)
        #expect(grid == input.grid)
        #expect(power == input.power)
        #expect(packed < 1 << 22)
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: WSPRError.self) {
            try WSPREncoder.symbols(callsign: "ABCDEF", grid: "IO91",
                                    powerDBm: 23) // no digit
        }
        #expect(throws: WSPRError.self) {
            try WSPREncoder.symbols(callsign: "M0ABC", grid: "IO9",
                                    powerDBm: 23) // short grid
        }
        #expect(throws: WSPRError.self) {
            try WSPREncoder.symbols(callsign: "M0ABC", grid: "ZZ91",
                                    powerDBm: 23) // grid letters past R
        }
        #expect(throws: WSPRError.self) {
            try WSPREncoder.symbols(callsign: "M0ABC", grid: "IO91",
                                    powerDBm: 99) // power out of range
        }
    }

    @Test func toneSpacingAndDurationMatchTheProtocol() {
        #expect(abs(WSPREncoder.toneSpacingHz - 1.4648) < 0.0001)
        #expect(abs(WSPREncoder.symbolDuration - 0.682666) < 0.0001)
        // A whole frame is ~110.6 s — inside the 180 s PTT watchdog.
        let frame = WSPREncoder.symbolDuration * 162
        #expect(frame > 110 && frame < 111)
    }

    @Test func toneStepsUpByOneSpacingPerSymbol() {
        let base = 1_500.0
        #expect(WSPREncoder.toneHz(forSymbol: 0, baseHz: base) == base)
        let third = WSPREncoder.toneHz(forSymbol: 3, baseHz: base)
        #expect(abs(third - base - 3 * WSPREncoder.toneSpacingHz) < 1e-9)
    }
}

@Suite("WSPR beacon")
struct WSPRBeaconTests {
    func makeReadySession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    // MARK: - Slot arithmetic

    @Test func slotsStartOneSecondIntoAnEvenUTCMinute() {
        let calendar = Calendar.utcCalendar
        for offset in stride(from: 0, to: 240, by: 7) {
            let now = Date(timeIntervalSince1970: 1_700_000_000
                           + Double(offset))
            let start = WSPRBeacon.nextSlotStart(after: now)
            let parts = calendar.dateComponents([.minute, .second], from: start)
            #expect((parts.minute ?? 0) % 2 == 0)
            #expect(parts.second == 1)
            #expect(start > now)
            #expect(start.timeIntervalSince(now) <= 121)
        }
    }

    // MARK: - Transmission

    @Test @MainActor func aFrameKeysEverySymbolThenUnkeys() async throws {
        let (session, transport) = try await makeReadySession()
        let beacon = WSPRBeacon(session: session)
        beacon.symbolDuration = .microseconds(200) // compress 110 s to ~30 ms

        let symbols = try WSPREncoder.symbols(callsign: "M0ABC",
                                              grid: "IO91", powerDBm: 23)
        await beacon.transmitOneFrame(symbols: symbols,
                                      band: WSPRBand.all.first { $0.name == "20 m" }!,
                                      start: Date())

        let log = await transport.rigState.toneLog
        let tones = log.compactMap { $0 }
        #expect(tones.count == 162)
        #expect(log.last == .some(nil)) // TA0; — the unkey
        // Every tone sits on the WSPR grid above the base tone.
        for (index, tone) in tones.enumerated() {
            let expected = WSPREncoder.toneHz(forSymbol: symbols[index],
                                              baseHz: beacon.baseToneHz)
            #expect(abs(tone - expected) < 0.01)
        }
        #expect(beacon.transmissionCount == 1)
        await session.disconnect()
    }

    @Test @MainActor func aFrameSetsTheDialAndDigiMode() async throws {
        let (session, transport) = try await makeReadySession()
        let beacon = WSPRBeacon(session: session)
        beacon.symbolDuration = .microseconds(100)
        let band = WSPRBand.all.first { $0.name == "30 m" }!

        await beacon.transmitOneFrame(
            symbols: try WSPREncoder.symbols(callsign: "M0ABC", grid: "IO91",
                                             powerDBm: 23),
            band: band, start: Date())

        let rig = await transport.rigState
        #expect(rig.vfoA == band.dialHz)
        #expect(rig.modeCode == "6") // DIGI
        #expect(rig.transmitting == false) // unkeyed at the end
        await session.disconnect()
    }

    @Test @MainActor func withoutASessionItFailsRatherThanKeying() async {
        let beacon = WSPRBeacon()
        await beacon.transmitOneFrame(symbols: [0, 1, 2],
                                      band: WSPRBand.all[0], start: Date())
        #expect(beacon.phase == .failed("Not connected"))
        #expect(beacon.transmissionCount == 0)
    }

    @Test @MainActor func startRejectsABadCallsignBeforeKeying() async throws {
        let (session, transport) = try await makeReadySession()
        let beacon = WSPRBeacon(session: session)
        beacon.start(callsign: "NOTACALL", grid: "IO91", powerDBm: 23,
                     band: WSPRBand.all[0])
        #expect(beacon.phase == .failed("Bad callsign “NOTACALL”"))
        let log = await transport.rigState.toneLog
        #expect(log.isEmpty)
        await session.disconnect()
    }

    @Test @MainActor func stopUnkeysTheRadio() async throws {
        let (session, transport) = try await makeReadySession()
        let beacon = WSPRBeacon(session: session)
        try await session.setDigiTone(hz: 1_500) // pretend a frame is running
        await beacon.stop()
        let log = await transport.rigState.toneLog
        #expect(log.last == .some(nil))
        let rig = await transport.rigState
        #expect(rig.transmitting == false)
        #expect(beacon.phase == .idle)
        await session.disconnect()
    }
}

@Suite("Clock sync")
struct ClockSyncTests {
    @Test func clockRoundTripsThroughTheSimulator() async throws {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()

        try await session.setClock(secondsSinceMidnight: 13 * 3_600
                                   + 55 * 60 + 32)
        #expect(try await session.readClock() == 13 * 3_600 + 55 * 60 + 32)

        // Wraps rather than throwing.
        try await session.setClock(secondsSinceMidnight: 86_400 + 61)
        #expect(try await session.readClock() == 61)
        await session.disconnect()
    }

    @Test @MainActor func syncSetsTheRadioClockAndRecordsDrift() async throws {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        // Radio 90 s ahead of whatever the phone says.
        let parts = Calendar.utcCalendar.dateComponents(
            [.hour, .minute, .second], from: Date())
        let nowSeconds = (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60
            + (parts.second ?? 0)
        await transport.setRig { $0.clockSeconds = (nowSeconds + 90) % 86_400 }

        let rig = RigController()
        rig.attachForTesting(session)
        await rig.syncClock()

        #expect(rig.lastClockSync != nil)
        let drift = try #require(rig.clockDriftSeconds)
        #expect(abs(drift - 90) <= 2)

        let after = try await session.readClock()
        #expect(abs(after - nowSeconds) <= 2)
        await session.disconnect()
    }
}
