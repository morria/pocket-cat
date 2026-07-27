// Spectrum fragment reassembly (docs/qmx-panadapter.md §6): ordering,
// gaps, truncation, unknown flags, and the new-frame-resets rule.

import Foundation
import Testing
@testable import CATBridgeCore

/// Build fragments the same way the firmware does (spec_frag_build).
private func fragments(seq: UInt8, bins: [UInt8], sampleRate: UInt32,
                       mtuPayload: Int) -> [Data] {
    let cap0 = mtuPayload - 12
    let capn = mtuPayload - 5
    var frags: [[UInt8]] = []
    var first = 0
    while first < bins.count {
        let cap = frags.isEmpty ? cap0 : capn
        let count = min(cap, bins.count - first)
        var out: [UInt8] = [seq, UInt8(frags.count), 0]
        if frags.isEmpty {
            out.append(0) // flags
            out.append(contentsOf: [0, 0])
            out.append(contentsOf: [UInt8(bins.count & 0xFF),
                                    UInt8(bins.count >> 8)])
            out.append(contentsOf: [
                UInt8(sampleRate & 0xFF), UInt8((sampleRate >> 8) & 0xFF),
                UInt8((sampleRate >> 16) & 0xFF),
                UInt8((sampleRate >> 24) & 0xFF),
            ])
        } else {
            out.append(contentsOf: [UInt8(first & 0xFF), UInt8(first >> 8)])
        }
        out.append(contentsOf: bins[first..<(first + count)])
        frags.append(out)
        first += count
    }
    return frags.map { frag in
        var f = frag
        f[2] = UInt8(frags.count)
        return Data(f)
    }
}

@Suite struct SpectrumReassemblyTests {
    let bins256 = (0..<256).map { UInt8($0 % 256) }

    @Test func singleFragmentFrame() {
        var r = SpectrumReassembler()
        let bins = [UInt8](repeating: 42, count: 64)
        let frags = fragments(seq: 5, bins: bins, sampleRate: 48000,
                              mtuPayload: 244)
        #expect(frags.count == 1)
        let frame = r.ingest(frags[0])
        #expect(frame == SpectrumFrame(sequence: 5, sampleRateHz: 48000,
                                       bins: bins))
        #expect(frame?.dBFS(at: 0) == -21.0)
    }

    @Test func multiFragmentReassembly() {
        var r = SpectrumReassembler()
        let frags = fragments(seq: 9, bins: bins256, sampleRate: 48000,
                              mtuPayload: 244)
        #expect(frags.count == 2)
        #expect(r.ingest(frags[0]) == nil)
        let frame = r.ingest(frags[1])
        #expect(frame?.bins == bins256)
        #expect(frame?.sampleRateHz == 48000)
    }

    @Test func missingFragmentDropsFrameThenRecovers() {
        var r = SpectrumReassembler()
        let a = fragments(seq: 1, bins: bins256, sampleRate: 48000,
                          mtuPayload: 244)
        let b = fragments(seq: 2, bins: bins256, sampleRate: 48000,
                          mtuPayload: 244)
        #expect(r.ingest(a[0]) == nil)
        // frag 0 of the NEXT frame resets pending reassembly (§3.3).
        #expect(r.ingest(b[0]) == nil)
        #expect(r.ingest(b[1])?.sequence == 2)
        #expect(r.framesDropped == 1)
    }

    @Test func sequenceGapsAreCounted() {
        var r = SpectrumReassembler()
        for seq: UInt8 in [1, 2, 5] { // 3 and 4 dropped by the bridge
            for frag in fragments(seq: seq, bins: bins256,
                                  sampleRate: 48000, mtuPayload: 244) {
                _ = r.ingest(frag)
            }
        }
        #expect(r.sequenceGaps == 2)
        #expect(r.framesDropped == 0)
    }

    @Test func seqWrapIsNotAGap() {
        var r = SpectrumReassembler()
        for seq: UInt8 in [254, 255, 0, 1] {
            for frag in fragments(seq: seq, bins: bins256,
                                  sampleRate: 48000, mtuPayload: 244) {
                _ = r.ingest(frag)
            }
        }
        #expect(r.sequenceGaps == 0)
    }

    @Test func unknownFlagsDropped() {
        var r = SpectrumReassembler()
        var frag0 = [UInt8](fragments(seq: 1, bins: bins256,
                                      sampleRate: 48000,
                                      mtuPayload: 244)[0])
        frag0[3] = 0x80 // future format
        #expect(r.ingest(Data(frag0)) == nil)
    }

    @Test func duplicateAndOutOfOrderFragmentsDrop() {
        var r = SpectrumReassembler()
        let frags = fragments(seq: 3, bins: bins256, sampleRate: 48000,
                              mtuPayload: 244)
        #expect(r.ingest(frags[0]) == nil)
        #expect(r.ingest(frags[0]) == nil) // duplicate frag 0 restarts
        #expect(r.ingest(frags[1])?.sequence == 3) // completes the restart
        // Continuation with nothing pending is discarded.
        #expect(r.ingest(frags[1]) == nil)
    }

    @Test func truncatedAndGarbageInputsNeverCrash() {
        var r = SpectrumReassembler()
        #expect(r.ingest(Data()) == nil)
        #expect(r.ingest(Data([1])) == nil)
        #expect(r.ingest(Data([1, 0, 1])) == nil) // frag0 too short
        var junk = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let n = Int.random(in: 0...64, using: &junk)
            let data = Data((0..<n).map { _ in
                UInt8.random(in: 0...255, using: &junk)
            })
            _ = r.ingest(data)
        }
    }
}
