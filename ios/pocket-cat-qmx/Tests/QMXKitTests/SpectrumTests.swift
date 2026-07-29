// Panadapter end-to-end against the simulator: capability probe, Q9
// policy, frame flow through the real session, and stop semantics.

import CATBridgeCore
import Testing
@testable import QMXKit

@Suite("Panadapter ↔ QMX simulator")
struct PanadapterSimTests {
    func makeReadySession() async throws
        -> (TransceiverSession, QMXSimTransport) {
        let transport = QMXSimTransport()
        let session = TransceiverSession(transport: transport)
        try await session.start()
        return (session, transport)
    }

    @Test func probeReportsSupport() async throws {
        let (session, _) = try await makeReadySession()
        #expect(try await session.probeSpectrumSupport())
        await session.disconnect()
    }

    @Test func framesFlowAndCarrySampleRate() async throws {
        let (session, transport) = try await makeReadySession()
        try await session.setIQMode(true)
        #expect(try await session.readIQMode())
        #expect(await transport.rigState.iqMode)

        try await session.setSpectrum(bins: 256, fps: 30)
        var iterator = await session.spectrumFrames().makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first?.bins.count == 256)
        #expect(first?.sampleRateHz == 48000)
        #expect(second?.sequence == (first?.sequence ?? 0) &+ 1)
        await session.stopSpectrum()
        try? await session.setIQMode(false)
        #expect(await transport.rigState.iqMode == false)
        await session.disconnect()
    }

    @Test func invalidConfigIsRejected() async throws {
        let (session, _) = try await makeReadySession()
        await #expect(throws: (any Error).self) {
            try await session.setSpectrum(bins: 100, fps: 15)
        }
        await #expect(throws: (any Error).self) {
            try await session.setSpectrum(bins: 256, fps: 0)
        }
        await session.disconnect()
    }
}

@Suite struct QMXSpectrumOffsetTests {
    @Test func vfoSitsAtQuarterSpanForTheQMXOffset() {
        // 48 kHz / 256 bins: +12 kHz IF = a quarter span, so the VFO is a
        // quarter in from the left (bin 64 of 256).
        let f = QMXSpectrum.vfoBinFraction(binCount: 256, sampleRateHz: 48000)
        #expect(abs(f - 0.25) < 0.01)
    }

    @Test func frequencyMappingPutsDCAtCentrePlusOffset() {
        // Frame centre (bin 128) is the VFO + 12 kHz DC bin.
        let vfo: UInt64 = 14_060_000
        let centre = QMXSpectrum.frequencyHz(
            bin: 128, binCount: 256, sampleRateHz: 48000, vfoHz: vfo)
        #expect(centre == Double(vfo) + 12_000)

        // And the VFO frequency itself lands at bin 64.
        let atVfo = QMXSpectrum.frequencyHz(
            bin: 64, binCount: 256, sampleRateHz: 48000, vfoHz: vfo)
        #expect(abs(atVfo - Double(vfo)) < 200) // one bin ≈ 187 Hz
    }
}
