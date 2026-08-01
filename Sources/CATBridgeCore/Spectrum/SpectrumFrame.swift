// Panadapter spectrum frames (docs/qmx-panadapter.md §3.3): fragment
// decode + reassembly. Pure logic, no CoreBluetooth — headless-testable.
//
//   frag 0 : [seq][frag=0][nfrags][flags][first_bin u16][bins_total u16]
//            [sample_rate_hz u32][bin bytes…]                 header 12 B
//   frag n : [seq][frag][nfrags][first_bin u16][bin bytes…]   header  5 B
//
// Bins are dBFS at 0.5 dB/LSB (0 = full scale). Bin 0 is the lowest
// frequency; bin binsTotal/2 is DC (the tuned frequency). Frames whose
// fragments are incomplete, inconsistent, or flag-unknown are dropped —
// never repaired, never retried. Dropped frames appear as `seq` gaps.

import Foundation

/// One complete spectrum frame.
public struct SpectrumFrame: Sendable, Equatable {
    public var sequence: UInt8
    public var sampleRateHz: UInt32
    /// dBFS at 0.5 dB/LSB, 0 = full scale; `bins.count` is the bin total.
    public var bins: [UInt8]

    public init(sequence: UInt8, sampleRateHz: UInt32, bins: [UInt8]) {
        self.sequence = sequence
        self.sampleRateHz = sampleRateHz
        self.bins = bins
    }

    /// The bin carrying DC — the tuned frequency itself, after the
    /// firmware's fftshift.
    public var dcBin: Int { bins.count / 2 }

    /// The trace with the DC spike interpolated away.
    ///
    /// A direct-conversion receiver leaks its local oscillator into the
    /// mixer output, which lands exactly on the tuned frequency. The
    /// firmware already subtracts each block's mean, and that removes a
    /// *static* offset — but the leakage drifts in amplitude and phase, so
    /// a residue survives and window leakage smears it into the
    /// neighbouring bins. On a dummy load it paints a strong carrier at the
    /// VFO that is not on the air.
    ///
    /// Every SDR display treats this the same way: replace the affected
    /// bins with the slope across their nearest clean neighbours. It is
    /// cosmetic by nature — a real signal sitting exactly on the VFO is
    /// interpolated along with the artifact, which is why the receiver's
    /// own audio, not the waterfall, is the judge of what is there.
    ///
    /// - Parameters:
    ///   - bin: where the leakage lands. Defaults to the frame centre,
    ///     which is right for a receiver whose stream is centred on its
    ///     oscillator. A radio that shifts its I/Q — the QMX moves it
    ///     +12 kHz — leaves the leakage at the *hardware* oscillator
    ///     instead, well away from the stream's own DC bin, which is why
    ///     subtracting the block mean does nothing for it.
    ///   - halfWidth: bins either side to replace. One covers the Hann
    ///     window's main-lobe spill.
    public func binsWithDCSuppressed(atBin bin: Int? = nil,
                                     halfWidth: Int = 1) -> [UInt8] {
        guard halfWidth >= 0, bins.count > 2 * (halfWidth + 1) else {
            return bins
        }
        var out = bins
        let centre = bin ?? dcBin
        let low = centre - halfWidth - 1
        let high = centre + halfWidth + 1
        guard low >= 0, high < bins.count else { return bins }

        // Bins are dB *below* full scale, so linear interpolation across
        // them is a straight line in dB — which is what the eye expects.
        let span = Double(high - low)
        for index in (low + 1)..<high {
            let t = Double(index - low) / span
            let value = (1 - t) * Double(bins[low]) + t * Double(bins[high])
            out[index] = UInt8(value.rounded())
        }
        return out
    }

    /// Signal level of one bin in dBFS.
    public func dBFS(at index: Int) -> Double {
        -Double(bins[index]) / 2.0
    }
}

/// Reassembles notification fragments into frames. Not thread-safe by
/// itself — owned and driven by the session actor.
public struct SpectrumReassembler: Sendable {
    public private(set) var framesDropped = 0
    /// Sequence numbers missing between delivered frames (firmware-side
    /// drops surface here; §3.4).
    public private(set) var sequenceGaps = 0

    private var sequence: UInt8 = 0
    private var nfrags: UInt8 = 0
    private var nextFrag: UInt8 = 0
    private var binsTotal: Int = 0
    private var sampleRate: UInt32 = 0
    private var bins: [UInt8] = []
    private var filled: Int = 0
    private var pending = false
    private var lastDelivered: UInt8?

    public init() {}

    /// Feed one notification; returns a frame when it completes one.
    public mutating func ingest(_ data: Data) -> SpectrumFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        let seq = bytes[0]
        let frag = bytes[1]
        let total = bytes[2]

        if frag == 0 {
            // A new frame always resets whatever was pending (§3.3).
            if pending { drop() }
            guard bytes.count >= 12, total >= 1 else { return nil }
            let flags = bytes[3]
            guard flags == 0 else { return nil } // unknown format: drop
            let firstBin = Int(bytes[4]) | (Int(bytes[5]) << 8)
            guard firstBin == 0 else { return nil }
            binsTotal = Int(bytes[6]) | (Int(bytes[7]) << 8)
            guard binsTotal >= 1, binsTotal <= 4096 else { return nil }
            sampleRate = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8)
                | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24)
            sequence = seq
            nfrags = total
            nextFrag = 1
            bins = [UInt8](repeating: 0, count: binsTotal)
            let payload = bytes[12...]
            guard payload.count <= binsTotal else { return drop() }
            bins.replaceSubrange(0..<payload.count, with: payload)
            filled = payload.count
            pending = true
        } else {
            guard pending, seq == sequence, frag == nextFrag,
                  total == nfrags, bytes.count >= 5 else {
                if pending { _ = drop() }
                return nil
            }
            let firstBin = Int(bytes[3]) | (Int(bytes[4]) << 8)
            let payload = bytes[5...]
            guard firstBin == filled,
                  firstBin + payload.count <= binsTotal else {
                return drop()
            }
            bins.replaceSubrange(firstBin..<(firstBin + payload.count),
                                 with: payload)
            filled += payload.count
            nextFrag += 1
        }

        guard pending, nextFrag == nfrags else { return nil }
        guard filled == binsTotal else { return drop() }
        pending = false
        if let last = lastDelivered {
            let expected = last &+ 1
            if sequence != expected {
                sequenceGaps += Int(sequence &- expected)
            }
        }
        lastDelivered = sequence
        return SpectrumFrame(sequence: sequence, sampleRateHz: sampleRate,
                             bins: bins)
    }

    @discardableResult
    private mutating func drop() -> SpectrumFrame? {
        pending = false
        framesDropped += 1
        return nil
    }

    /// Forget everything (link bounce, stream restart).
    public mutating func reset() {
        pending = false
        lastDelivered = nil
    }
}
