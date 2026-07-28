// Band plan classification, band-stacking registers, memories and recents.
// All device-side, so none of this needs a radio or the simulator.

import CATBridgeKit
import Foundation
import Testing
@testable import QMXKit

@Suite("Station memory")
struct StationMemoryTests {
    /// A fresh store per test — `UserDefaults.standard` would leak state
    /// between them and into the app.
    @MainActor
    func makeStore() -> StationMemory {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return StationMemory(defaults: suite)
    }

    // MARK: - Band plan

    @Test(arguments: [(14_074_000, "20m"), (7_030_000, "40m"),
                      (1_840_000, "160m"), (50_313_000, "6m"),
                      (10_136_000, "30m")])
    func frequenciesClassifyIntoBands(_ pair: (hz: UInt64, band: String)) {
        #expect(BandPlan.band(containing: pair.hz)?.title == pair.band)
    }

    @Test func frequenciesBetweenBandsBelongToNone() {
        // The gap between 20 m and 17 m.
        #expect(BandPlan.band(containing: 15_000_000) == nil)
        #expect(BandPlan.band(containing: 500_000) == nil)
    }

    @Test func everyBandsSegmentsFallInsideItsOwnRange() {
        for band in BandPlan.all {
            for segment in band.segments {
                #expect(band.range.contains(segment.hz),
                        "\(band.title) \(segment.name) is outside the band")
            }
        }
    }

    @Test func everyBandDefaultsInsideItsOwnRange() {
        for band in BandPlan.all {
            #expect(band.range.contains(band.defaultHz))
        }
    }

    @Test func thePlanCoversTheBandsTheQMXCanReach() {
        let titles = BandPlan.all.map(\.title)
        #expect(titles.contains("60m"))   // QMX covers it; the FT-891 doesn't
        #expect(titles.contains("6m"))
    }

    /// Every WSPR segment must match the beacon's own dial table, or the
    /// band bar would send people to a frequency the beacon doesn't use.
    @Test func wsprSegmentsMatchTheBeaconDialTable() {
        for band in BandPlan.all {
            guard let segment = band.segments.first(where: {
                $0.name == "WSPR"
            }) else { continue }
            let dial = WSPRBand.all.first {
                band.range.contains($0.dialHz)
            }
            #expect(dial?.dialHz == segment.hz,
                    "\(band.title) WSPR segment disagrees with WSPRBand")
        }
    }

    // MARK: - Band stacking

    @Test @MainActor func aBandRemembersWhereYouLeftIt() {
        let store = makeStore()
        let twenty = BandPlan.all.first { $0.title == "20m" }!
        let forty = BandPlan.all.first { $0.title == "40m" }!

        #expect(store.stackEntry(for: twenty) == nil)
        store.noteVisit(hz: 14_025_000, mode: .cw)
        store.noteVisit(hz: 7_140_000, mode: .lsb)

        #expect(store.stackEntry(for: twenty)?.hz == 14_025_000)
        #expect(store.stackEntry(for: twenty)?.mode == .cw)
        #expect(store.stackEntry(for: forty)?.hz == 7_140_000)
    }

    @Test @MainActor func revisitingABandOverwritesItsRegister() {
        let store = makeStore()
        let twenty = BandPlan.all.first { $0.title == "20m" }!
        store.noteVisit(hz: 14_025_000, mode: .cw)
        store.noteVisit(hz: 14_250_000, mode: .usb)
        #expect(store.stackEntry(for: twenty)?.hz == 14_250_000)
        #expect(store.stackEntry(for: twenty)?.mode == .usb)
    }

    @Test @MainActor func visitsOutsideAnyBandAreIgnored() {
        let store = makeStore()
        store.noteVisit(hz: 15_000_000, mode: .usb)
        #expect(store.recents.isEmpty)
    }

    // MARK: - Recents

    @Test @MainActor func recentsKeepNewestFirst() {
        let store = makeStore()
        store.noteVisit(hz: 14_074_000, mode: .dataUSB)
        store.noteVisit(hz: 7_030_000, mode: .cw)
        #expect(store.recents.map(\.hz) == [7_030_000, 14_074_000])
    }

    /// Tuning across a band shouldn't fill the list with near-duplicates.
    @Test @MainActor func smallMovesCollapseIntoOneEntry() {
        let store = makeStore()
        store.noteVisit(hz: 14_074_000, mode: .cw)
        store.noteVisit(hz: 14_074_100, mode: .cw)
        store.noteVisit(hz: 14_074_200, mode: .cw)
        #expect(store.recents.count == 1)
        #expect(store.recents[0].hz == 14_074_200)
    }

    @Test @MainActor func returningToAFrequencyMovesItToTheTop() {
        let store = makeStore()
        store.noteVisit(hz: 14_074_000, mode: .cw)
        store.noteVisit(hz: 7_030_000, mode: .cw)
        store.noteVisit(hz: 14_074_000, mode: .cw)
        #expect(store.recents.map(\.hz) == [14_074_000, 7_030_000])
    }

    @Test @MainActor func recentsAreCapped() {
        let store = makeStore()
        for step in 0..<(StationMemory.recentsLimit + 6) {
            store.noteVisit(hz: 14_000_000 + UInt64(step) * 10_000, mode: .cw)
        }
        #expect(store.recents.count == StationMemory.recentsLimit)
    }

    @Test @MainActor func clearingRecentsLeavesTheBandStackAlone() {
        let store = makeStore()
        let twenty = BandPlan.all.first { $0.title == "20m" }!
        store.noteVisit(hz: 14_074_000, mode: .cw)
        store.clearRecents()
        #expect(store.recents.isEmpty)
        #expect(store.stackEntry(for: twenty)?.hz == 14_074_000)
    }

    // MARK: - Memories

    @Test @MainActor func storeRenameDeleteRoundTrip() {
        let store = makeStore()
        let channel = store.store(hz: 14_074_000, mode: .dataUSB)
        #expect(store.channels.count == 1)

        store.rename(channel.id, to: "FT8 watering hole")
        #expect(store.channels[0].name == "FT8 watering hole")

        store.delete(channel.id)
        #expect(store.channels.isEmpty)
    }

    @Test @MainActor func storedChannelsCarryTheirMode() {
        let store = makeStore()
        store.store(hz: 7_030_000, mode: .cw)
        #expect(store.channels[0].mode == .cw)
        #expect(store.channels[0].band?.title == "40m")
    }

    @Test @MainActor func namesDefaultToTheNearestKnownSegment() {
        let store = makeStore()
        store.store(hz: 14_074_000, mode: .dataUSB)
        #expect(store.channels[0].name == "20m FT8")
        // Far from any segment, fall back to the frequency itself.
        store.store(hz: 14_200_000, mode: .usb)
        #expect(store.channels[0].name.hasPrefix("20m 14.200"))
    }

    @Test @MainActor func groupingFollowsBandPlanOrder() {
        let store = makeStore()
        store.store(hz: 14_074_000, mode: .dataUSB)
        store.store(hz: 3_573_000, mode: .dataUSB)
        store.store(hz: 7_074_000, mode: .dataUSB)
        #expect(store.channelsByBand.map(\.band) == ["80m", "40m", "20m"])
    }

    @Test @MainActor func reorderingMovesTheRightRow() {
        let store = makeStore()
        store.store(hz: 14_074_000, mode: nil, name: "A")
        store.store(hz: 7_074_000, mode: nil, name: "B")
        store.store(hz: 3_573_000, mode: nil, name: "C")
        #expect(store.channels.map(\.name) == ["C", "B", "A"])

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.channels.map(\.name) == ["B", "A", "C"])
    }

    // MARK: - Persistence

    @Test @MainActor func everythingSurvivesARelaunch() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let first = StationMemory(defaults: suite)
        first.store(hz: 14_074_000, mode: .dataUSB, name: "Keeper")
        first.noteVisit(hz: 7_030_000, mode: .cw)

        let second = StationMemory(defaults: suite)
        #expect(second.channels.map(\.name) == ["Keeper"])
        #expect(second.channels[0].mode == .dataUSB)
        #expect(second.recents.map(\.hz) == [7_030_000])
        let forty = BandPlan.all.first { $0.title == "40m" }!
        #expect(second.stackEntry(for: forty)?.hz == 7_030_000)
    }

    @Test func modeTokensAreStableAcrossEveryMode() {
        for mode in OperatingMode.allCases {
            let token = try! #require(ModeToken.token(mode))
            #expect(ModeToken.mode(token) == mode)
        }
    }
}
