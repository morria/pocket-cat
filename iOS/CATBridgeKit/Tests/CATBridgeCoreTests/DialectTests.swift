// Dialect + value-type tests (docs/implementation.md §9.1).

import Foundation
import Testing
@testable import CATBridgeCore

@Suite struct FrequencyTests {
    @Test func integerHertzIsExact() {
        #expect(Frequency.megahertz(14.250).hertz == 14_250_000)
        #expect(Frequency.kilohertz(7040).hertz == 7_040_000)
        #expect(Frequency(hz: 14_074_000).megahertzValue == 14.074)
    }

    @Test func catDigitsPadding() {
        #expect(Frequency(hz: 14_250_000).catDigits(width: 9) == "014250000")
        #expect(Frequency(hz: 14_250_000).catDigits(width: 11)
                == "00014250000")
        #expect(Frequency(hz: 1_000_000_000).catDigits(width: 9) == nil)
    }

    @Test func comparableAndDescription() {
        #expect(Frequency(hz: 7_000_000) < Frequency(hz: 14_000_000))
        #expect(Frequency(hz: 14_250_000).description == "14.250.000 MHz")
    }
}

@Suite struct YaesuDialectTests {
    let dialect = YaesuDialect.ft891

    @Test func frequencyEncoding() throws {
        #expect(try dialect.setFrequency(Frequency(hz: 14_250_000)).wire
                == "FA014250000;")
        #expect(dialect.readFrequency.wire == "FA;")
        #expect(throws: (any Error).self) {
            _ = try dialect.setFrequency(Frequency(hz: 9_999_999_999))
        }
    }

    @Test(arguments: [
        (OperatingMode.lsb, "1"), (.usb, "2"), (.cw, "3"), (.fm, "4"),
        (.am, "5"), (.rtty, "6"), (.cwReverse, "7"), (.dataLSB, "8"),
        (.rttyReverse, "9"), (.dataFM, "A"), (.fmNarrow, "B"),
        (.dataUSB, "C"), (.amNarrow, "D"), (.c4fm, "E"), (.dataFMNarrow, "F"),
    ])
    func modeTableComplete(mode: OperatingMode, code: String) throws {
        // Yaesu newcat table, grounded in Hamlib newcat_mode_conv[].
        #expect(try dialect.setMode(mode).wire == "MD0\(code);")
        let parsed = try dialect.parse(reply: "MD0\(code);",
                                       to: dialect.readMode)
        #expect(parsed == .mode(mode))
    }

    @Test func replyParsing() throws {
        #expect(try dialect.parse(reply: "FA014074000;",
                                  to: dialect.readFrequency)
                == .frequency(Frequency(hz: 14_074_000)))
        #expect(try dialect.parse(reply: "ID0650;", to: dialect.readID)
                == .id("ID0650;"))
        let ptt = try #require(dialect.readPTT)
        #expect(try dialect.parse(reply: "TX0;", to: ptt) == .ptt(false))
        #expect(try dialect.parse(reply: "TX1;", to: ptt) == .ptt(true))
        #expect(try dialect.parse(reply: "TX2;", to: ptt) == .ptt(true))
        let sMeter = try #require(dialect.readSMeter)
        #expect(try dialect.parse(reply: "SM0100;", to: sMeter)
                == .sMeter(100))
    }

    @Test func infoParsing() throws {
        let reply = "IF001014250000+0000003000000;"
        let value = try dialect.parse(reply: reply, to: dialect.readInfo)
        guard case let .info(info) = value else {
            Issue.record("expected .info")
            return
        }
        #expect(info.frequency == Frequency(hz: 14_250_000))
        #expect(info.mode == .cw)
        #expect(info.isTransmitting == nil) // Yaesu IF has no TX flag
    }

    @Test func malformedRepliesThrow() throws {
        for bad in ["FA01;", "FAxxxxxxxxx;", "IFshort;", "FA014074000"] {
            #expect(throws: (any Error).self, "\(bad)") {
                _ = try dialect.parse(reply: bad, to: dialect.readFrequency)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try dialect.parse(reply: "MD0Z;", to: dialect.readMode)
        }
        let sMeter = try #require(dialect.readSMeter)
        #expect(throws: (any Error).self) {
            _ = try dialect.parse(reply: "SM0abc;", to: sMeter)
        }
    }

    @Test func unsolicitedParsing() {
        #expect(dialect.parseUnsolicited("FA014074000;")
                == .frequency(Frequency(hz: 14_074_000)))
        #expect(dialect.parseUnsolicited("XY123;") == nil)
    }

    @Test func pttAndFailsafe() {
        #expect(dialect.pttOn.wire == "TX1;")
        #expect(dialect.pttOn.isPTTOn)
        #expect(!dialect.pttOn.isIdempotent)
        #expect(dialect.pttOff.wire == "TX0;")
        #expect(dialect.failsafeString == "TX0;")
    }

    @Test func keyerText() throws {
        #expect(try dialect.keyerText("CQ CQ").wire == "KYCQ CQ;")
        #expect(throws: (any Error).self) {
            _ = try dialect.keyerText("bad;text")
        }
    }
}

@Suite struct KenwoodDialectTests {
    let dialect = KenwoodDialect.qmx

    @Test func frequencyEncoding11Digits() throws {
        #expect(try dialect.setFrequency(Frequency(hz: 7_074_000)).wire
                == "FA00007074000;")
        let parsed = try dialect.parse(reply: "FA00007074000;",
                                       to: dialect.readFrequency)
        #expect(parsed == .frequency(Frequency(hz: 7_074_000)))
    }

    @Test(arguments: [
        (OperatingMode.lsb, "1"), (.usb, "2"), (.cw, "3"), (.fm, "4"),
        (.am, "5"), (.rtty, "6"), (.cwReverse, "7"), (.rttyReverse, "9"),
    ])
    func modeTable(mode: OperatingMode, code: String) throws {
        #expect(try dialect.setMode(mode).wire == "MD\(code);")
    }

    @Test func unsupportedModesThrow() {
        #expect(throws: (any Error).self) {
            _ = try dialect.setMode(.c4fm)
        }
        #expect(throws: (any Error).self) {
            _ = try dialect.setMode(.dataUSB)
        }
    }

    @Test func pttSemantics() {
        // Kenwood: TX; keys (a SET), RX; unkeys — and TX; must never be
        // used as a read, so readPTT is nil.
        #expect(dialect.pttOn.wire == "TX;")
        #expect(dialect.pttOff.wire == "RX;")
        #expect(dialect.readPTT == nil)
        #expect(dialect.failsafeString == "RX;")
    }

    @Test func infoParsingCarriesTXFlag() throws {
        let rx = "IF00014074000     +0000000000300000000 ;"
        let tx = "IF00014074000     +0000000001300000000 ;"
        guard case let .info(rxInfo) = try dialect.parse(reply: rx,
                                                         to: dialect.readInfo),
              case let .info(txInfo) = try dialect.parse(reply: tx,
                                                         to: dialect.readInfo)
        else {
            Issue.record("expected .info")
            return
        }
        #expect(rxInfo.isTransmitting == false)
        #expect(txInfo.isTransmitting == true)
        #expect(rxInfo.frequency == Frequency(hz: 14_074_000))
        #expect(rxInfo.mode == .cw)
    }

    @Test func capabilitiesExcludeWhatQMXLacks() {
        #expect(!dialect.capabilities.contains(.rfPowerControl))
        #expect(!dialect.capabilities.contains(.sMeter))
        #expect(dialect.capabilities.contains(.ptt))
    }
}

@Suite struct DemuxTests {
    @Test func splitAcrossArbitraryChunks() {
        var demux = ResponseDemux()
        var frames: [String] = []
        for byte in Data("FA014074000;ID0650;".utf8) {
            frames += demux.ingest(Data([byte])) // 1-byte drip
        }
        #expect(frames == ["FA014074000;", "ID0650;"])
        #expect(demux.garbageFrames == 0)
    }

    @Test func multipleFramesOneChunk() {
        var demux = ResponseDemux()
        let frames = demux.ingest(Data("TX0;FA014074000;?;".utf8))
        #expect(frames == ["TX0;", "FA014074000;", "?;"])
    }

    @Test func binaryGarbageIsDroppedAndCounted() {
        var demux = ResponseDemux()
        var garbage = Data([0xF0, 0xF1, 0x00, 0x9C])
        garbage.append(Data(";FA014074000;".utf8))
        let frames = demux.ingest(garbage)
        #expect(frames == ["FA014074000;"])
        #expect(demux.garbageFrames == 1)
    }

    @Test func runawayWithoutTerminatorResyncs() {
        var demux = ResponseDemux()
        _ = demux.ingest(Data(repeating: UInt8(ascii: "x"),
                              count: 300))
        #expect(demux.garbageFrames >= 1)
        // Recovers for subsequent traffic (the partial tail corrupts the
        // first frame, like a real serial stream).
        _ = demux.ingest(Data("junk;".utf8))
        let frames = demux.ingest(Data("ID0650;".utf8))
        #expect(frames == ["ID0650;"])
    }

    @Test func fuzzNeverCrashes() {
        var demux = ResponseDemux()
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for _ in 0..<200 {
            var bytes = [UInt8]()
            for _ in 0..<((seed % 64) + 1) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
            }
            _ = demux.ingest(Data(bytes))
        }
        // Still functional afterwards.
        _ = demux.ingest(Data(";".utf8))
        let frames = demux.ingest(Data("FA014074000;".utf8))
        #expect(frames.contains("FA014074000;"))
    }
}
