// Integration: the real TransceiverSession actor driven end-to-end
// against the QMX simulator — connect/identify, the four-mode MD surface,
// the GET-only power meter, and the QMX command wrappers.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("Session ↔ QMX simulator")
struct SimSessionTests {
    func makeReadySession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func connectsAndIdentifies() async throws {
        let (session, _) = try await makeReadySession()
        let frequency = try await session.readFrequency()
        #expect(frequency.hertz == 14_060_000)
        let capabilities = await session.capabilities
        #expect(!capabilities.contains(.menuAccess)) // QMX: MM/ML instead
        #expect(!capabilities.contains(.rfPowerControl)) // PC is GET-only
        await session.disconnect()
    }

    @Test func frequencyAndModeControl() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setFrequency(Frequency(hz: 7_030_000))
        try await session.setMode(QMXMode.digi.operatingMode)
        let rig = await transport.rigState
        #expect(rig.vfoA == 7_030_000)
        #expect(rig.modeCode == "6")
        // No USB via MD on a QMX.
        await #expect(throws: CATBridgeError.unsupportedMode(.usb)) {
            try await session.setMode(.usb)
        }
        await session.disconnect()
    }

    @Test func powerMeterIsGetOnlyTenths() async throws {
        let (session, _) = try await makeReadySession()
        let watts = try await session.readPower()
        #expect(watts == 4.5)
        await #expect(throws:
            CATBridgeError.unsupportedCapability(.rfPowerControl)) {
            try await session.setPower(watts: 5)
        }
        await session.disconnect()
    }

    @Test func sidebandViaQ1() async throws {
        let (session, transport) = try await makeReadySession()
        #expect(try await session.readSideband() == .usb)
        try await session.setSideband(.lsb)
        #expect(try await session.readSideband() == .lsb)
        #expect(await transport.rigState.lsb)
        await session.disconnect()
    }

    @Test func ritRoundTrip() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setRIT(enabled: true)
        #expect(try await session.readRITEnabled())
        try await session.sendRITOffset(150)
        #expect(await transport.rigState.ritOffset == 150)
        #expect(try await session.readRITOffset() == 150)
        try await session.sendRITOffset(-30)
        #expect(try await session.readRITOffset() == -30) // absolute mode
        try await session.clearRIT()
        #expect(try await session.readRITOffset() == 0)
        await session.disconnect()
    }

    @Test func splitAndVFOB() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setSplit(true)
        #expect(try await session.readSplit())
        try await session.setVFOB(Frequency(hz: 7_016_000))
        #expect(try await session.readVFOB().hertz == 7_016_000)
        #expect(await transport.rigState.vfoB == 7_016_000)
        await session.disconnect()
    }

    @Test func keyerSpeedTypedSetting() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.set(.keyerSpeed, to: 25)
        #expect(try await session.read(.keyerSpeed) == 25)
        #expect(await transport.rigState.keyerSpeed == 25)
        let supported = await session.supportedSettings
        #expect(supported == [.keyerSpeed])
        await session.disconnect()
    }

    @Test func firmwareVersionAndMode() async throws {
        let (session, _) = try await makeReadySession()
        #expect(try await session.readFirmwareVersion() == "1_02_006QMX")
        #expect(try await session.readQMXMode() == .cw)
        await session.disconnect()
    }
}
