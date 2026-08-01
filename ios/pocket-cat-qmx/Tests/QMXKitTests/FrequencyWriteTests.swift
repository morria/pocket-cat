// Setting the VFO on a real QMX didn't take, while everything else worked.
//
// The library writes the TS-480 form — `FA` plus eleven zero-padded digits
// — and the QMX CAT reference documents a short form as well
// (`FA7030000;`). Which one this firmware honours isn't settled, so the app
// reads back after a set and retries once in the other form.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("Frequency writes")
struct FrequencyWriteTests {
    @MainActor
    func makeRig(acceptsPadded: Bool) async throws
        -> (RigController, QMXSimTransport) {
        var sim = QMXSimRig()
        sim.acceptsPaddedFrequencySets = acceptsPadded
        let transport = QMXSimTransport(rig: sim)
        let session = TransceiverSession(transport: transport)
        try await session.start()
        let rig = RigController()
        rig.attachForTesting(session)
        return (rig, transport)
    }

    @Test @MainActor func aRadioTakingThePaddedFormNeedsNoRetry() async throws {
        let (rig, transport) = try await makeRig(acceptsPadded: true)
        rig.tune(to: Frequency(hz: 14_074_000))
        try await Task.sleep(for: .milliseconds(200))

        #expect(await transport.rigState.vfoA == 14_074_000)
        #expect(rig.frequencyWriteForm == .padded)
    }

    /// The failure seen on hardware: the padded set is ignored, so the app
    /// must notice and try the form the manual shows.
    @Test @MainActor func aRadioRejectingThePaddedFormStillTunes() async throws {
        let (rig, transport) = try await makeRig(acceptsPadded: false)
        rig.tune(to: Frequency(hz: 14_074_000))
        try await Task.sleep(for: .milliseconds(300))

        #expect(await transport.rigState.vfoA == 14_074_000,
                "the fallback did not tune the radio")
        #expect(rig.frequencyWriteForm == .unpadded)
    }

    @Test @MainActor func theFormIsUntestedUntilSomethingIsTuned() async throws {
        let (rig, _) = try await makeRig(acceptsPadded: true)
        #expect(rig.frequencyWriteForm == .untested)
    }

    /// A retry must not fight a drag: if the dial has moved on, the
    /// read-back belongs to a stale target and is not a failed write.
    @Test @MainActor func aMovingDialIsNotTreatedAsFailure() async throws {
        let (rig, transport) = try await makeRig(acceptsPadded: true)
        rig.tune(to: Frequency(hz: 14_074_000))
        rig.tune(to: Frequency(hz: 14_075_000))
        rig.tune(to: Frequency(hz: 14_076_000))
        try await Task.sleep(for: .milliseconds(300))

        #expect(await transport.rigState.vfoA == 14_076_000)
    }
}

@Suite("Tuning the active VFO")
struct ActiveVFOTuningTests {
    @MainActor
    func makeRig() async throws -> (RigController, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        let rig = RigController()
        rig.attachForTesting(session)
        return (rig, transport)
    }

    @Test @MainActor func tuningOnVFOAWritesVFOA() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setVFOMode(.vfoA)
        rig.tune(to: Frequency(hz: 14_074_000))
        try await Task.sleep(for: .milliseconds(250))

        let state = await transport.rigState
        #expect(state.vfoA == 14_074_000)
        #expect(state.vfoB == 7_030_000, "VFO B should not have moved")
    }

    /// `FA` addresses VFO A specifically, but the frequency on screen comes
    /// from `IF`, which reports whichever VFO is active. On VFO B that made
    /// the display right and every write land on the wrong VFO.
    @Test @MainActor func tuningOnVFOBWritesVFOB() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setVFOMode(.vfoB)
        rig.tune(to: Frequency(hz: 10_136_000))
        try await Task.sleep(for: .milliseconds(250))

        let state = await transport.rigState
        #expect(state.vfoB == 10_136_000, "tuning did not reach VFO B")
        #expect(state.vfoA == 14_060_000, "VFO A should not have moved")
    }

    /// Split receives on A, so the dial still tunes A.
    @Test @MainActor func tuningInSplitWritesTheReceiveVFO() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setVFOMode(.split)
        rig.tune(to: Frequency(hz: 21_074_000))
        try await Task.sleep(for: .milliseconds(250))

        #expect(await transport.rigState.vfoA == 21_074_000)
    }
}
