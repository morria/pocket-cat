// Passband layer tests (docs/passband.md §6): tables, wrapper round
// trips against the simulator, rejection behaviour, geometry, and
// coalescing under a synthetic drag.

import CATBridgeCore
import Foundation
import Testing
@testable import FTX1Kit

@Suite struct PassbandTableTests {
    @Test func everyIndexMapsPerMode() {
        for family in [PassbandTables.cwFamily, PassbandTables.ssbFamily] {
            for index in family.indices {
                let hz = family.widthHz(at: index)
                #expect(hz != nil && hz! > 0)
            }
            #expect(family.widthHz(at: 0) == nil)      // rig default
            #expect(family.widthHz(at: family.indices.upperBound) == nil)
        }
    }

    @Test func widthsAreStrictlyIncreasing() {
        for family in [PassbandTables.cwFamily, PassbandTables.ssbFamily] {
            let widths = family.indices.map { family.widths[$0] }
            #expect(widths == widths.sorted())
            #expect(Set(widths).count == widths.count)
        }
    }

    @Test func indexForWidthRoundTrips() {
        for family in [PassbandTables.cwFamily, PassbandTables.ssbFamily] {
            for index in family.indices {
                let hz = family.widths[index]
                #expect(family.index(forWidthHz: hz) == index)
            }
            // Between two widths → the next one up; beyond max → max.
            #expect(family.index(forWidthHz: family.widths[1] + 1) == 2)
            #expect(family.index(forWidthHz: 99_999)
                    == family.indices.upperBound - 1)
        }
    }

    @Test func narrowBoundaryMatchesTable() {
        let cw = PassbandTables.cwFamily
        #expect(cw.requiresNarrow(index: cw.index(forWidthHz: 500)))
        #expect(!cw.requiresNarrow(index: cw.index(forWidthHz: 800)))
        let ssb = PassbandTables.ssbFamily
        #expect(ssb.requiresNarrow(index: ssb.index(forWidthHz: 1800)))
        #expect(!ssb.requiresNarrow(index: ssb.index(forWidthHz: 1950)))
    }

    @Test func modeFamilies() {
        #expect(PassbandTables.family(for: .usb) != nil)
        #expect(PassbandTables.family(for: .cw)?.narrowMax == 500)
        #expect(PassbandTables.family(for: .dataUSB)?.narrowMax == 500)
        #expect(PassbandTables.family(for: .am) == nil)
        #expect(PassbandTables.family(for: .fmNarrow) == nil)
    }
}

@Suite("Passband ↔ FTX-1 simulator")
struct PassbandSimTests {
    func makeReadySession() async throws
        -> (TransceiverSession, FTX1SimTransport) {
        let transport = FTX1SimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func readPassbandPopulatesEverything() async throws {
        let (session, _) = try await makeReadySession()
        let state = await session.readPassband(mode: .usb)
        #expect(state.shiftHz == 0)
        #expect(state.widthIndex == 15)
        #expect(state.widthHz == PassbandTables.ssbFamily.widths[15])
        #expect(state.notchEnabled == false)
        #expect(state.notchHz == 1000)
        #expect(state.contourEnabled == false)
        #expect(state.contourHz == 800)
        #expect(state.autoNotchEnabled == false)
        await session.disconnect()
    }

    @Test func shiftRoundTripAndSnap() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setIFShift(hz: 240)
        #expect(try await session.readIFShift() == 240)
        // Snaps to 20 Hz and clamps to ±1200 before the wire.
        try await session.setIFShift(hz: 333)
        #expect(await transport.rigState.shiftHz == 340)
        try await session.setIFShift(hz: -5000)
        #expect(try await session.readIFShift() == -1200)
        try await session.setIFShift(hz: 0)
        #expect(try await session.readIFShift() == 0)
        await session.disconnect()
    }

    @Test func widthWriteOrdersNarrowFirst() async throws {
        let (session, transport) = try await makeReadySession()
        // 300 Hz CW: needs NA1 before SH.
        try await session.setMode(.cw)
        let index = PassbandTables.cwFamily.index(forWidthHz: 300)
        try await session.setWidth(index: index, mode: .cw)
        let journal = await transport.journalEntries
        let naAt = journal.lastIndex(of: "NA01;")
        let shAt = journal.lastIndex(of: String(format: "SH01%02d;", index))
        #expect(naAt != nil && shAt != nil && naAt! < shAt!)
        #expect(try await session.readWidthIndex() == index)
        #expect(try await session.readNarrow())

        // 2400 Hz: back to wide.
        let wide = PassbandTables.cwFamily.index(forWidthHz: 2400)
        try await session.setWidth(index: wide, mode: .cw)
        #expect(try await session.readNarrow() == false)
        await session.disconnect()
    }

    @Test func notchRoundTripAndClamp() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setNotch(enabled: true)
        try await session.setNotch(hz: 1234)
        #expect(try await session.readNotchEnabled())
        #expect(try await session.readNotchHz() == 1230)
        // Clamped before the wire — the sim rejects >320 tens with ?; and
        // the value must never be rejected.
        try await session.setNotch(hz: 99_999)
        #expect(try await session.readNotchHz() == 3200)
        try await session.setNotch(hz: 1)
        #expect(try await session.readNotchHz() == 10)
        #expect(await transport.rigState.notchOn)
        await session.disconnect()
    }

    @Test func contourAndAutoNotchRoundTrip() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setContour(enabled: true)
        try await session.setContour(hz: 651)
        #expect(try await session.readContourEnabled())
        #expect(try await session.readContourHz() == 651)
        try await session.setAutoNotch(enabled: true)
        #expect(try await session.readAutoNotch())
        try await session.setAutoNotch(enabled: false)
        #expect(try await session.readAutoNotch() == false)
        await session.disconnect()
    }

    @Test func amModeRejectsPassbandButKeepsAutoNotch() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setMode(.am)
        let state = await session.readPassband(mode: .am)
        #expect(state.shiftHz == nil)
        #expect(state.widthIndex == nil)
        #expect(state.autoNotchEnabled == false) // BC works in every mode
        // A direct write is rejected by the radio, surfaced as an error.
        await #expect(throws: (any Error).self) {
            try await session.setIFShift(hz: 100)
            _ = try await session.readIFShift()
        }
        await session.disconnect()
    }
}

@Suite struct PassbandGeometryTests {
    let geometry = PassbandGeometry(width: 390)

    @Test func xHzRoundTrips() {
        for hz in stride(from: 0, through: 3400, by: 170) {
            let x = geometry.x(forHz: hz)
            #expect(abs(geometry.hz(forX: x) - hz) <= 5)
        }
        #expect(geometry.hz(forX: -50) == 0)
        #expect(geometry.hz(forX: 900) == 3400)
    }

    @Test func edgeZonesBeatBodyAndDontOverlapAtNarrowWidths() {
        // Narrowest SSB width: 200 Hz. Edge zones must still resolve
        // deterministically (left wins at the midpoint tie).
        let widthHz = 200
        let edges = geometry.passbandEdges(widthHz: widthHz, shiftHz: 0)
        let lowX = geometry.x(forHz: edges.lowHz)
        let highX = geometry.x(forHz: edges.highHz)
        let mid = (lowX + highX) / 2
        let target = geometry.hitTarget(x: mid, widthHz: widthHz,
                                        shiftHz: 0, notchHz: nil,
                                        notchEnabled: false)
        #expect(target == .leftEdge || target == .rightEdge)

        // At a wide width the centre is body.
        let wide = geometry.hitTarget(x: geometry.width / 2, widthHz: 2400,
                                      shiftHz: 0, notchHz: nil,
                                      notchEnabled: false)
        #expect(wide == .body)
    }

    @Test func notchMarkerWinsWhenEnabled() {
        let x = geometry.x(forHz: 1700)
        let hit = geometry.hitTarget(x: x, widthHz: 2400, shiftHz: 0,
                                     notchHz: 1700, notchEnabled: true)
        #expect(hit == .notch)
        let without = geometry.hitTarget(x: x, widthHz: 2400, shiftHz: 0,
                                         notchHz: 1700, notchEnabled: false)
        #expect(without == .body)
    }

    @Test func sensitivityCurve() {
        #expect(PassbandGeometry.sensitivity(verticalDistance: 0) == 1.0)
        #expect(abs(PassbandGeometry.sensitivity(verticalDistance: 100)
                    - 0.1) < 1e-9)
        #expect(abs(PassbandGeometry.sensitivity(verticalDistance: 400)
                    - 0.1) < 1e-9)
        #expect(abs(PassbandGeometry.sensitivity(verticalDistance: -50)
                    - 0.55) < 1e-9)
    }
}

@Suite struct PassbandCoalescerTests {
    @MainActor
    @Test func sixtyHzDragCoalescesAndEndsOnFinalValue() async throws {
        let sent = SentLog()
        let coalescer = PassbandWriteCoalescer<String>(
            interval: .milliseconds(50)) { _, value in
            await sent.append(value)
        }
        // ~0.5 s of 60 Hz drag events.
        for value in 0..<30 {
            coalescer.submit("shift", value: value)
            try await Task.sleep(for: .milliseconds(8))
        }
        await coalescer.settle()
        let values = await sent.values
        // ≤ 1 write per 50 ms plus the leading edge, and never the backlog.
        #expect(coalescer.sendCount <= 8)
        #expect(values.last == 29)
    }

    @MainActor
    @Test func independentKeysDrainSeparately() async throws {
        let sent = SentLog()
        let coalescer = PassbandWriteCoalescer<String>(
            interval: .milliseconds(20)) { key, value in
            await sent.append(value, key: key)
        }
        coalescer.submit("shift", value: 1)
        coalescer.submit("notch", value: 2)
        await coalescer.settle()
        #expect(await sent.byKey["shift"] == [1])
        #expect(await sent.byKey["notch"] == [2])
    }
}

actor SentLog {
    var values: [Int] = []
    var byKey: [String: [Int]] = [:]

    func append(_ value: Int, key: String = "") {
        values.append(value)
        byKey[key, default: []].append(value)
    }
}
