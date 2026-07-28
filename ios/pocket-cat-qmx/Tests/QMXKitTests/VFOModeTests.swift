// VFO A / B / Split as one selector, matching the radio's own FR model.
// Split is not a third VFO — it is receive on A, transmit on B — and the
// old on/off toggle sitting beside nothing made that impossible to see.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("VFO mode")
struct VFOModeTests {
    @MainActor
    func makeRig() async throws -> (RigController, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        let rig = RigController()
        rig.attachForTesting(session)
        return (rig, transport)
    }

    @Test @MainActor func selectingEachModeReachesTheRadio() async throws {
        let (rig, transport) = try await makeRig()

        await rig.setVFOMode(.vfoB)
        #expect(await transport.rigState.vfoMode == 1)
        #expect(rig.vfoMode == .vfoB)

        await rig.setVFOMode(.split)
        #expect(await transport.rigState.vfoMode == 2)
        #expect(await transport.rigState.split)

        await rig.setVFOMode(.vfoA)
        #expect(await transport.rigState.vfoMode == 0)
        #expect(await transport.rigState.split == false)
    }

    /// Split and the VFO selector are two views of one radio state; they
    /// must not be able to disagree.
    @Test @MainActor func splitStaysInStepWithTheSelector() async throws {
        let (rig, _) = try await makeRig()
        await rig.setVFOMode(.split)
        #expect(rig.splitEnabled)
        await rig.setVFOMode(.vfoA)
        #expect(!rig.splitEnabled)
    }

    @Test @MainActor func refreshReadsBackWhatTheRadioHas() async throws {
        let (rig, transport) = try await makeRig()
        await transport.setRig { $0.vfoMode = 2; $0.split = true }
        await rig.refreshSecondaryState()
        #expect(rig.vfoMode == .split)
        #expect(rig.splitEnabled)
    }

    /// The mode row was blank on connect because `state.mode` only fills
    /// after the library's first poll.
    @Test @MainActor func modeIsKnownAfterConnectNotAfterTheFirstPoll()
        async throws {
        let (rig, transport) = try await makeRig()
        await transport.setRig { $0.modeCode = "6" } // DIGI
        await rig.refreshSecondaryState()
        #expect(rig.currentMode == .digi)
        #expect(rig.currentMode?.family == .digi)
    }
}
