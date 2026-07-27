// Profile round-trip, diff, and apply — driven through the real session
// against the simulator, plus pure JSON round-trip and store behavior.

import CATBridgeCore
import Foundation
import Testing
@testable import FT891Kit

@Suite("Profiles")
struct ProfileTests {
    @Test func jsonRoundTrip() throws {
        var profile = RadioProfile(
            name: "Field Day",
            notes: "SSB portable",
            savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        profile.menu["05-06"] = 3
        profile.menu["01-01"] = 300
        profile.operating.vfoAHz = 14_285_000
        profile.operating.modeCode = "2"
        profile.operating.powerWatts = 50

        let data = try profile.encoded()
        let decoded = try RadioProfile.decode(data)
        #expect(decoded == profile)

        // Files are human-readable engineering units, not wire digits.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"05-06\" : 3"))
    }

    @Test func newerSchemaRefused() throws {
        var profile = RadioProfile(name: "future", savedAt: Date())
        profile.schemaVersion = RadioProfile.currentSchemaVersion + 1
        let data = try profile.encoded()
        #expect(throws: (any Error).self) {
            _ = try RadioProfile.decode(data)
        }
    }

    @Test func captureDiffApplyAgainstSim() async throws {
        let transport = FT891SimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()

        // Capture the sim's defaults.
        let baseline = try await ProfileEngine.capture(
            from: session, name: "baseline", savedAt: Date())
        #expect(baseline.menu.count == MenuCatalog.profileItems.count)
        #expect(baseline.operating.vfoAHz == 14_074_000)

        // Perturb the radio: two menu items + operating state.
        let catRate = try #require(MenuCatalog.byID["05-06"])
        let agcFast = try #require(MenuCatalog.byID["01-01"])
        try await session.writeMenuValue(catRate, value: 0)
        try await session.writeMenuValue(agcFast, value: 1000)
        try await session.setFrequency(Frequency(hz: 3_573_000))

        // Diff: exactly the two changed items.
        let diffs = try await ProfileEngine.diff(baseline, against: session)
        #expect(Set(diffs.map(\.item.id)) == ["05-06", "01-01"])

        // Apply the baseline back; radio returns to captured state.
        let results = try await ProfileEngine.apply(
            diffs: diffs, operating: baseline.operating, to: session)
        #expect(results.allSatisfy { $0.outcome == .applied })
        #expect(try await session.readMenuValue(catRate) == 3)
        #expect(try await session.readMenuValue(agcFast) == 300)
        #expect(try await session.readFrequency().hertz == 14_074_000)

        let after = try await ProfileEngine.diff(baseline, against: session)
        #expect(after.isEmpty)
        await session.disconnect()
    }

    @Test func captureRefusedInFrontPanelMenu() async throws {
        let transport = FT891SimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        await transport.setRig { $0.frontPanelMenuActive = true }
        await #expect(throws: ProfileEngineError.frontPanelMenuActive) {
            _ = try await ProfileEngine.capture(
                from: session, name: "x", savedAt: Date())
        }
        await session.disconnect()
    }

    @Test func storeSaveListDeleteRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft891-tests-\(UUID().uuidString)")
        let store = ProfileStore(directory: directory)

        var profile = RadioProfile(name: "Contest/CW: A?",
                                   savedAt: Date())
        profile.menu["05-06"] = 3
        let saved = try await store.save(profile)
        #expect(saved.url.lastPathComponent.hasSuffix(
            ".\(RadioProfile.fileExtension)"))

        // Same name saves to a distinct file, not an overwrite.
        _ = try await store.save(profile)
        var listed = try await store.list()
        #expect(listed.count == 2)

        let renamed = try await store.rename(saved, to: "CW Sprint")
        #expect(renamed.profile.name == "CW Sprint")

        for stored in try await store.list() {
            try await store.delete(stored)
        }
        listed = try await store.list()
        #expect(listed.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func forwardCompatibleUnknownMenuKeys() throws {
        var profile = RadioProfile(name: "future", savedAt: Date())
        profile.menu["99-99"] = 7   // written by a newer app
        profile.menu["05-06"] = 2
        let entries = ProfileEngine.orderedMenuEntries(profile)
        #expect(entries.count == 1)
        #expect(entries.first?.0.id == "05-06")
    }
}
