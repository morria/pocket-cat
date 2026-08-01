// A direct-conversion receiver leaks its local oscillator onto the tuned
// frequency. The firmware subtracts each block's mean, which removes a
// static offset, but the leakage drifts — so a residue survives and paints
// a carrier at the VFO even into a dummy load.

import Testing
@testable import CATBridgeCore

@Suite("Spectrum DC suppression")
struct SpectrumDCTests {
    /// Bins are dB below full scale: small numbers are strong signals.
    func frame(bins: [UInt8]) -> SpectrumFrame {
        SpectrumFrame(sequence: 0, sampleRateHz: 48_000, bins: bins)
    }

    @Test func theCentreSpikeIsFlattenedIntoTheNoiseAroundIt() {
        var bins = [UInt8](repeating: 200, count: 64)  // flat noise floor
        bins[32] = 10                                  // the DC artifact
        let cleaned = frame(bins: bins).binsWithDCSuppressed()

        #expect(cleaned[32] == 200, "the DC spike survived")
        #expect(cleaned.count == bins.count)
    }

    /// Hann leakage spreads the artifact either side of centre.
    @Test func theBinsEitherSideAreCoveredToo() {
        var bins = [UInt8](repeating: 200, count: 64)
        bins[31] = 90
        bins[32] = 10
        bins[33] = 90
        let cleaned = frame(bins: bins).binsWithDCSuppressed()

        #expect(cleaned[31] == 200)
        #expect(cleaned[32] == 200)
        #expect(cleaned[33] == 200)
    }

    @Test func signalsAwayFromCentreAreUntouched() {
        var bins = [UInt8](repeating: 200, count: 64)
        bins[12] = 40   // a real signal
        bins[50] = 60   // another
        bins[32] = 10   // the artifact
        let cleaned = frame(bins: bins).binsWithDCSuppressed()

        #expect(cleaned[12] == 40, "a real signal was flattened")
        #expect(cleaned[50] == 60, "a real signal was flattened")
        #expect(cleaned[32] == 200)
    }

    /// Interpolation follows the slope, so a tilted floor stays tilted
    /// rather than developing a step at centre.
    @Test func aSlopingNoiseFloorIsInterpolatedNotFlattened() {
        var bins = (0..<64).map { UInt8(150 + $0) }
        bins[32] = 5
        let cleaned = frame(bins: bins).binsWithDCSuppressed()

        // With halfWidth 1 the clean neighbours are bins 30 and 34 —
        // 180 and 184 — so centre lands halfway, at 182.
        #expect(cleaned[32] == 182)
    }

    @Test func widerSuppressionCoversMoreBins() {
        var bins = [UInt8](repeating: 200, count: 64)
        for index in 29...35 { bins[index] = 20 }
        let cleaned = frame(bins: bins).binsWithDCSuppressed(halfWidth: 3)
        for index in 29...35 {
            #expect(cleaned[index] == 200, "bin \(index) not suppressed")
        }
    }

    @Test func tinyFramesAreLeftAlone() {
        let bins: [UInt8] = [10, 20]
        #expect(frame(bins: bins).binsWithDCSuppressed() == bins)
        #expect(frame(bins: []).binsWithDCSuppressed() == [])
    }

    @Test func theDCBinIsTheMiddleOfTheTrace() {
        #expect(frame(bins: [UInt8](repeating: 0, count: 256)).dcBin == 128)
        #expect(frame(bins: [UInt8](repeating: 0, count: 64)).dcBin == 32)
    }
}
