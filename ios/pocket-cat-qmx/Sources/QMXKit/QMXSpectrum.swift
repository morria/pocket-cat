// Panadapter frequency model for the QMX (docs/qmx-panadapter.md §6).
//
// The QMX presents its I/Q baseband at a +12 kHz IF: the stream's DC bin
// (frame centre, bins/2) is the VFO frequency PLUS 12 kHz, not the VFO
// itself. So the tuned signal sits a quarter-span below centre. Confirmed
// by the SteffenLav/qmx-panadapter project (ESP32-P4 / M5Stack Tab5),
// which shifts bin selection by n_bins/4 for the same reason.
//
// The firmware stays radio-agnostic (frames carry only sample rate); this
// QMX-specific offset lives here, on the app side, per the plan's §1.1
// split. Verify the exact value against a real radio at M4 bring-up.

import CATBridgeKit
import Foundation

public enum QMXSpectrum {
    /// The QMX's I/Q IF offset. Frame centre = VFO + this.
    public static let ifOffsetHz = 12_000

    /// Q9 (I/Q mode) is session-only and occasionally needs a couple of
    /// tries to take at connect; the reference client retries up to 4.
    public static let iqModeAttempts = 4

    /// The frequency a given bin represents, given the tuned VFO. Bin
    /// `binCount/2` is the +IF DC bin; the VFO itself lands `ifOffsetHz`
    /// below it.
    public static func frequencyHz(bin: Int, binCount: Int,
                                   sampleRateHz: UInt32,
                                   vfoHz: UInt64) -> Double {
        let binHz = Double(sampleRateHz) / Double(binCount)
        let dcHz = Double(vfoHz) + Double(ifOffsetHz) // frame centre
        return dcHz + Double(bin - binCount / 2) * binHz
    }

    /// The bin carrying the receiver's oscillator leakage.
    ///
    /// Not the frame's DC bin. The QMX shifts its I/Q by +12 kHz, so the
    /// stream's centre is VFO + 12 kHz while the hardware oscillator — and
    /// therefore its leakage — stays at the VFO, a quarter-span down. The
    /// firmware's mean subtraction cleans the stream's DC bin, where there
    /// is nothing to clean; this is the bin that actually needs covering.
    public static func leakageBin(binCount: Int,
                                  sampleRateHz: UInt32) -> Int {
        let binHz = Double(sampleRateHz) / Double(binCount)
        let bin = Double(binCount) / 2 - Double(ifOffsetHz) / binHz
        return max(0, min(binCount - 1, Int(bin.rounded())))
    }

    /// Fractional bin position of the VFO across the frame (0…1). For a
    /// 48 kHz / +12 kHz QMX this is 0.25 — a quarter in from the left.
    public static func vfoBinFraction(binCount: Int,
                                      sampleRateHz: UInt32) -> Double {
        let binHz = Double(sampleRateHz) / Double(binCount)
        let vfoBin = Double(binCount) / 2 - Double(ifOffsetHz) / binHz
        return max(0, min(1, vfoBin / Double(binCount - 1)))
    }
}
