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
