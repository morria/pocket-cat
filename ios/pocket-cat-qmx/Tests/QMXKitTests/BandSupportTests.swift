// Reading the radio's own `Band config.` table, which is what the band bar
// filters against. A QMX is built around one filter board, so the bands it
// covers are a property of the unit.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("Band support")
struct BandSupportTests {
    func makeReadySession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func readsTheBandTableFromTheMenuTree() async throws {
        let (session, _) = try await makeReadySession()
        let bands = try #require(
            await QMXBandSupport.read(using: QMXMenuClient(session: session)))

        // The simulator ships an 80/40/20 filter board.
        #expect(bands.map(\.metres) == [80, 40, 20])
        #expect(bands.map(\.bandTitle) == ["80m", "40m", "20m"])
        #expect(bands.map(\.column) == [0, 1, 2])
        await session.disconnect()
    }

    @Test func carriesEachBandsConfiguredCentre() async throws {
        let (session, _) = try await makeReadySession()
        let bands = try #require(
            await QMXBandSupport.read(using: QMXMenuClient(session: session)))
        #expect(bands.first { $0.metres == 20 }?.centerHz == 14_074_000)
        #expect(bands.first { $0.metres == 40 }?.centerHz == 7_074_000)
        await session.disconnect()
    }

    @Test func mapsOntoBandPlanEntriesInPlanOrder() async throws {
        let (session, _) = try await makeReadySession()
        let bands = try #require(
            await QMXBandSupport.read(using: QMXMenuClient(session: session)))
        #expect(bands.planBands.map(\.title) == ["80m", "40m", "20m"])
        // And the lookup the bar uses to pick a landing frequency.
        let twenty = BandPlan.all.first { $0.title == "20m" }!
        #expect(bands.entry(for: twenty)?.centerHz == 14_074_000)
        await session.disconnect()
    }

    @Test func bandsTheRadioHasButThePlanDoesNotAreDropped() {
        let odd = [SupportedBand(metres: 4, centerHz: nil, column: 0),
                   SupportedBand(metres: 20, centerHz: nil, column: 1)]
        #expect(odd.planBands.map(\.title) == ["20m"])
    }

    @Test @MainActor func aConnectPopulatesTheControllersBandList() async throws {
        let (session, _) = try await makeReadySession()
        let rig = RigController()
        rig.attachForTesting(session)
        #expect(rig.supportedBands == nil)

        await rig.readSupportedBands()
        #expect(rig.supportedBands?.map(\.metres) == [80, 40, 20])
        await session.disconnect()
    }

    /// A radio that doesn't answer must not empty the band bar.
    @Test @MainActor func anUnreadableRadioLeavesTheListUnknown() async {
        let rig = RigController()
        await rig.readSupportedBands() // no session at all
        #expect(rig.supportedBands == nil)
    }
}
