// Profiles: JSON codec guarantees, and capture → mutate → diff → apply
// against the simulator through the real session.

import CATBridgeCore
import Foundation
import Testing
@testable import QMXKit

@Suite struct ProfileCodecTests {
    @Test func jsonRoundTrip() throws {
        var profile = QMXProfile(name: "Field Day", notes: "POTA kit")
        // ISO-8601 keeps whole seconds; use a representable timestamp so
        // equality holds through the codec.
        profile.savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        profile.menu["Audio|AGC settings|Threshold S"] = "4"
        profile.operating.vfoAHz = 14_060_000
        profile.operating.modeCode = "3"
        profile.operating.sideband = "USB"
        profile.operating.keyerSpeed = 22

        let decoded = try QMXProfile.decode(try profile.encoded())
        #expect(decoded == profile)
    }

    @Test func newerSchemaRefused() throws {
        var profile = QMXProfile(name: "future")
        profile.schemaVersion = QMXProfile.currentSchemaVersion + 1
        let data = try profile.encoded()
        #expect(throws: (any Error).self) {
            _ = try QMXProfile.decode(data)
        }
    }

    @Test func unknownMenuKeysSurviveRoundTrip() throws {
        // A profile saved by newer firmware may hold paths this app has
        // never seen — they must persist untouched.
        var profile = QMXProfile(name: "forward")
        profile.menu["Some 2030 feature|Novel knob"] = "42"
        let decoded = try QMXProfile.decode(try profile.encoded())
        #expect(decoded.menu["Some 2030 feature|Novel knob"] == "42")
    }
}

@Suite("Profiles ↔ QMX simulator")
struct ProfileSimTests {
    func makeSession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func captureReadsWholeTreeAndOperatingState() async throws {
        let (session, _) = try await makeSession()
        let profile = try await ProfileEngine.capture(
            name: "bench", session: session)

        #expect(profile.menu["Audio|AGC settings|Threshold S"] == "4")
        #expect(profile.menu["Band config.|RF gain (dB)[2]"] == "74")
        #expect(profile.menu["CW|Choose filters|0"] == "ENABLED")
        #expect(profile.operating.vfoAHz == 14_060_000)
        #expect(profile.operating.modeCode == "3")
        #expect(profile.operating.sideband == "USB")
        #expect(profile.operating.keyerSpeed == 20)
        #expect(profile.firmwareVersion == "1_02_006QMX")
        await session.disconnect()
    }

    @Test func diffAndApplyRestoreSavedState() async throws {
        let (session, transport) = try await makeSession()
        let saved = try await ProfileEngine.capture(
            name: "before", session: session)

        // Drift the radio: menu values and operating state.
        await transport.setRig { rig in
            rig.menuRoot[0].children[0].children[1].values = ["9"] // Thresh
            rig.menuRoot[4].children[1].values[2] = "60"           // RF gain
            rig.keyerSpeed = 33
            rig.vfoA = 7_030_000
            rig.modeCode = "6"
        }

        let diffs = try await ProfileEngine.diff(saved, session: session)
        let keys = Set(diffs.map(\.key))
        #expect(keys.contains("Audio|AGC settings|Threshold S"))
        #expect(keys.contains("Band config.|RF gain (dB)[2]"))
        #expect(diffs.count == 2)

        let results = await ProfileEngine.apply(saved, diffs: diffs,
                                                session: session)
        #expect(results.allSatisfy { $0.succeeded })

        let rig = await transport.rigState
        #expect(rig.menuRoot[0].children[0].children[1].values == ["4"])
        #expect(rig.menuRoot[4].children[1].values[2] == "74")
        // Operating state restored too.
        #expect(rig.vfoA == 14_060_000)
        #expect(rig.modeCode == "3")
        #expect(rig.keyerSpeed == 20)
        await session.disconnect()
    }

    @Test func storeCRUD() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(directory: directory)
        var profile = QMXProfile(name: "one")
        profile.menu["A|B"] = "1"

        let stored = try await store.save(profile)
        #expect(try await store.list().count == 1)
        let renamed = try await store.rename(stored, to: "two")
        #expect(renamed.profile.name == "two")
        try await store.delete(renamed)
        #expect(try await store.list().isEmpty)
    }
}
