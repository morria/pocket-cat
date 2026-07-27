// Integration: the real TransceiverSession actor driven end-to-end against
// the FT-891 simulator — connect, operate, FT-891 command wrappers, and
// the signed-EX raw-CAT path.

import CATBridgeCore
import Testing
@testable import FT891Kit

@Suite("Session ↔ FT-891 simulator")
struct SimSessionTests {
    func makeReadySession() async throws
        -> (TransceiverSession, FT891SimTransport) {
        let transport = FT891SimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func connectsAndIdentifies() async throws {
        let (session, _) = try await makeReadySession()
        let frequency = try await session.readFrequency()
        #expect(frequency.hertz == 14_074_000)
        let capabilities = await session.capabilities
        #expect(capabilities.contains(.menuAccess))
        await session.disconnect()
    }

    @Test func frequencyAndModeControl() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setFrequency(Frequency(hz: 7_030_000))
        try await session.setMode(.cw)
        let rig = await transport.rigState
        #expect(rig.vfoA == 7_030_000)
        #expect(rig.modeCode == "3")
        await session.disconnect()
    }

    @Test func powerControl() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setPower(watts: 30)
        let watts = try await session.readPower()
        #expect(watts == 30)
        await session.disconnect()
    }

    @Test func tunerWrapper() async throws {
        let (session, _) = try await makeReadySession()
        #expect(try await session.readTunerState() == .off)
        try await session.setTuner(enabled: true)
        #expect(try await session.readTunerState() == .on)
        try await session.startTuneCycle()
        // The sim reports `tuning` for two AC reads, then lands on `on`.
        var state = try await session.readTunerState()
        #expect(state == .tuning)
        state = try await session.readTunerState()
        while state == .tuning {
            state = try await session.readTunerState()
        }
        #expect(state == .on)
        await session.disconnect()
    }

    @Test func splitClarifierAndVFOB() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setSplit(.on)
        #expect(try await session.readSplit() == .on)

        try await session.setClarifier(enabled: true)
        #expect(try await session.readClarifierEnabled())
        try await session.nudgeClarifier(by: 150)
        try await session.nudgeClarifier(by: -50)
        try await session.clearClarifier()

        try await session.setVFOB(Frequency(hz: 7_200_000))
        #expect(try await session.readVFOB().hertz == 7_200_000)
        try await session.swapVFOs()
        #expect(try await session.readFrequency().hertz == 7_200_000)
        await session.disconnect()
    }

    @Test func meterAndStatusWrappers() async throws {
        let (session, _) = try await makeReadySession()
        let swr = try await session.readMeter(.swr)
        #expect((0...255).contains(swr))
        #expect(try await session.readBusy() == false)
        #expect(try await session.readFrontPanelMenuActive() == false)
        await session.disconnect()
    }

    @Test func menuReadWriteUnsigned() async throws {
        let (session, transport) = try await makeReadySession()
        let catRate = try #require(MenuCatalog.byID["05-06"])
        let initial = try await session.readMenuValue(catRate)
        #expect(initial == 3) // sim default 38400
        try await session.writeMenuValue(catRate, value: 1)
        #expect(try await session.readMenuValue(catRate) == 1)
        let rig = await transport.rigState
        #expect(rig.menu["0506"] == "1")
        await session.disconnect()
    }

    @Test func menuReadWriteSignedGoesViaRawCAT() async throws {
        let (session, _) = try await makeReadySession()
        let signedItems = MenuCatalog.items.filter(\.isSigned)
        #expect(signedItems.count == 11)
        for item in signedItems {
            let range = item.kind.range
            let target = max(range.lowerBound, min(-1, range.upperBound))
            try await session.writeMenuValue(item, value: target)
            #expect(try await session.readMenuValue(item) == target,
                    "\(item.id) signed round-trip failed")
        }
        await session.disconnect()
    }

    @Test func rejectsWriteToReadOnlyItems() async throws {
        let (session, _) = try await makeReadySession()
        let version = try #require(MenuCatalog.byID["18-01"])
        await #expect(throws: CATBridgeError.self) {
            try await session.writeMenuValue(version, value: 1)
        }
        await session.disconnect()
    }

    @Test func unknownMenuNumberGetsRadioRejected() async throws {
        let (session, _) = try await makeReadySession()
        await #expect(throws: CATBridgeError.self) {
            _ = try await session.readMenuItem("9999")
        }
        await session.disconnect()
    }

    @Test func autoInformationPushesDialTurns() async throws {
        let transport = FT891SimTransport()
        var policy = PollingPolicy.default
        policy.enableAutoInformation = true
        let session = TransceiverSession(transport: transport,
                                         policy: policy)
        try await session.start()
        await transport.turnDial(to: 21_074_000)
        // The push is unsolicited; give the event loop a moment.
        for _ in 0..<50 {
            if await transport.rigState.autoInformation,
               case let snapshots = await session.snapshots(),
               let first = await snapshots.first(where: { _ in true }),
               first.frequency?.hertz == 21_074_000 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshots = await session.snapshots()
        let snapshot = await snapshots.first(where: { _ in true })
        #expect(snapshot?.frequency?.hertz == 21_074_000)
        await session.disconnect()
    }
}
