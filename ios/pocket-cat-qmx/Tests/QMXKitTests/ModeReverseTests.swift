// The QMX's four MD modes are two families × two tone senses. These pin
// that mapping, because getting it wrong sends the radio to the wrong mode
// silently — MD accepts all four codes.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("Mode families and reverse")
struct ModeReverseTests {
    @Test func everyModeSplitsIntoAFamilyAndASense() {
        #expect(QMXMode.cw.family == .cw)
        #expect(QMXMode.cwReverse.family == .cw)
        #expect(QMXMode.digi.family == .digi)
        #expect(QMXMode.fskReverse.family == .digi)

        #expect(QMXMode.cw.isReversed == false)
        #expect(QMXMode.cwReverse.isReversed)
        #expect(QMXMode.digi.isReversed == false)
        #expect(QMXMode.fskReverse.isReversed)
    }

    @Test func familyAndSenseReconstructEveryMode() {
        for mode in QMXMode.allCases {
            #expect(QMXMode.mode(family: mode.family,
                                 reversed: mode.isReversed) == mode)
        }
    }

    @Test func reversingTwiceIsIdentity() {
        for mode in QMXMode.allCases {
            #expect(mode.reversedCounterpart.reversedCounterpart == mode)
            #expect(mode.reversedCounterpart.family == mode.family)
            #expect(mode.reversedCounterpart.isReversed != mode.isReversed)
        }
    }

    @Test func reverseMapsToTheRightWireCodes() {
        // MD codes per esp32s3/docs/references/qmx-cat.md.
        #expect(QMXMode.cw.reversedCounterpart.rawValue == "7")
        #expect(QMXMode.digi.reversedCounterpart.rawValue == "9")
        #expect(QMXMode.cwReverse.reversedCounterpart.rawValue == "3")
        #expect(QMXMode.fskReverse.reversedCounterpart.rawValue == "6")
    }

    // MARK: - Against the simulator

    @MainActor
    func makeRig() async throws -> (RigController, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        let rig = RigController()
        rig.attachForTesting(session)
        return (rig, transport)
    }

    @Test @MainActor func togglingReverseKeepsTheFamily() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setMode(.digi)
        #expect(await transport.rigState.modeCode == "6")

        await rig.setReversed(true)
        #expect(await transport.rigState.modeCode == "9") // FSK-R

        await rig.setReversed(false)
        #expect(await transport.rigState.modeCode == "6")
    }

    @Test @MainActor func switchingFamilyKeepsTheSense() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setMode(.cwReverse) // reversed CW
        await rig.setModeFamily(.digi)
        // Reversed, so DIGI must land on FSK-R rather than DIGI.
        #expect(await transport.rigState.modeCode == "9")

        await rig.setReversed(false)
        await rig.setModeFamily(.cw)
        #expect(await transport.rigState.modeCode == "3")
    }

    @Test @MainActor func settingTheSenseItAlreadyHasSendsNothing() async throws {
        let (rig, transport) = try await makeRig()
        await rig.setMode(.cw)
        await rig.setReversed(false)
        #expect(await transport.rigState.modeCode == "3")
    }
}
