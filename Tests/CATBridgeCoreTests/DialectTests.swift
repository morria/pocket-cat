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

    @Test func autoInformationCommands() throws {
        #expect(dialect.capabilities.contains(.autoInformation))
        let enable = try #require(dialect.enableAutoInformation)
        #expect(enable.wire == "AI1;")
        #expect(enable.replyPrefix == nil) // Yaesu set: silence
        let disable = try #require(dialect.disableAutoInformation)
        #expect(disable.wire == "AI0;")
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
        (OperatingMode.cw, "3"), (.rtty, "6"), (.cwReverse, "7"),
        (.rttyReverse, "9"),
    ])
    func modeTable(mode: OperatingMode, code: String) throws {
        // QMX MD accepts ONLY 3/6/7/9 (cat_1_02_006); sideband is Q1.
        #expect(try dialect.setMode(mode).wire == "MD\(code);")
    }

    @Test func unsupportedModesThrow() {
        for mode in [OperatingMode.c4fm, .dataUSB, .lsb, .usb, .am, .fm] {
            #expect(throws: (any Error).self) {
                _ = try dialect.setMode(mode)
            }
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

    @Test func capabilitiesMatchQMXSubset() {
        // cat_1_02_006: SM reads dB, PC is a GET-only power meter (so no
        // .rfPowerControl — power is not settable), no EX menu (QMX menus
        // are the MM/ML Menu Manager, above the dialect).
        #expect(!dialect.capabilities.contains(.rfPowerControl))
        #expect(dialect.readPower != nil)
        #expect(dialect.capabilities.contains(.sMeter))
        #expect(!dialect.capabilities.contains(.menuAccess))
        #expect(dialect.capabilities.contains(.ptt))
    }

    @Test func noAutoInformationOnKenwood() {
        #expect(!dialect.capabilities.contains(.autoInformation))
        #expect(dialect.enableAutoInformation == nil)
        #expect(dialect.disableAutoInformation == nil)
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

@Suite struct PowerControlDialectTests {
    @Test func yaesuPowerEncodingAndParsing() throws {
        let dialect = YaesuDialect.ft891
        let read = try #require(dialect.readPower)
        #expect(read.wire == "PC;")
        #expect(try dialect.parse(reply: "PC100;", to: read) == .power(100))
        #expect(try dialect.parse(reply: "PC005;", to: read) == .power(5))
        #expect(try dialect.setPower(watts: 5).wire == "PC005;")
        #expect(try dialect.setPower(watts: 100).wire == "PC100;")
        #expect(dialect.powerRange == 5...100)
    }

    @Test(arguments: [0, 4, 101, -5])
    func yaesuPowerRangeRejected(watts: Int) {
        #expect(throws: (any Error).self) {
            _ = try YaesuDialect.ft891.setPower(watts: watts)
        }
    }

    @Test func yaesuMalformedPowerThrows() {
        let dialect = YaesuDialect.ft891
        let read = dialect.readPower!
        for bad in ["PC;", "PC10;", "PC1000;", "PCxxx;", "PC100"] {
            #expect(throws: (any Error).self) {
                _ = try dialect.parse(reply: bad, to: read)
            }
        }
    }

    @Test func yaesuUnsolicitedPowerFrame() {
        // Auto-Information can push PC when the operator turns the knob.
        #expect(YaesuDialect.ft891.parseUnsolicited("PC050;") == .power(50))
    }

    @Test func kenwoodPowerIsGetOnlyTenths() throws {
        let dialect = KenwoodDialect.qmx
        let read = try #require(dialect.readPower)
        #expect(read.wire == "PC;")
        // cat_1_02_006: PC returns tenths of a watt, variable width.
        #expect(try dialect.parse(reply: "PC45;", to: read) == .power(4.5))
        #expect(try dialect.parse(reply: "PC5;", to: read) == .power(0.5))
        #expect(try dialect.parse(reply: "PC120;", to: read) == .power(12.0))
        // GET-only: no set range, and setPower keeps the throwing default.
        #expect(dialect.powerRange == nil)
        #expect(throws:
            CATBridgeError.unsupportedCapability(.rfPowerControl)) {
            _ = try dialect.setPower(watts: 5)
        }
    }

    @Test func kenwoodSMeterInDecibels() throws {
        let dialect = KenwoodDialect.qmx
        let read = try #require(dialect.readSMeter)
        #expect(read.wire == "SM;")
        #expect(try dialect.parse(reply: "SM12;", to: read) == .sMeter(12))
        // Tolerates a TS-480-style frame from older tooling.
        #expect(try dialect.parse(reply: "SM00005;", to: read) == .sMeter(5))
        #expect(throws: (any Error).self) {
            _ = try dialect.parse(reply: "SM;", to: read)
        }
    }
}

@Suite struct RigSettingDialectTests {
    let yaesu = YaesuDialect.ft891

    @Test(arguments: [
        (RigSetting.afGain, "AG0;", "AG0128;", 128),
        (.rfGain, "RG0;", "RG0255;", 255),
        (.squelch, "SQ0;", "SQ0000;", 0),
        (.micGain, "MG;", "MG050;", 50),
        (.keyerSpeed, "KS;", "KS020;", 20),
        (.breakIn, "BI;", "BI1;", 1),
        (.noiseBlanker, "NB0;", "NB00;", 0),
        (.noiseReduction, "NR0;", "NR01;", 1),
        (.preamp, "PA0;", "PA01;", 1),
        (.attenuator, "RA0;", "RA00;", 0),
        (.narrow, "NA0;", "NA01;", 1),
        (.filterWidth, "SH0;", "SH012;", 12),
    ])
    func yaesuSettingRoundTrip(setting: RigSetting, readWire: String,
                               reply: String, value: Int) throws {
        let read = try #require(yaesu.readSetting(setting))
        #expect(read.wire == readWire)
        #expect(try yaesu.parse(reply: reply, to: read)
                == .setting(setting, value))
        // Set encodes to exactly the reply the radio would echo.
        #expect(try yaesu.setSetting(setting, to: value).wire == reply)
    }

    @Test func yaesuEverySettingSupported() {
        for setting in RigSetting.allCases {
            #expect(yaesu.readSetting(setting) != nil)
            #expect(yaesu.settingRange(setting) != nil)
        }
    }

    @Test func yaesuOutOfRangeSettingThrows() {
        #expect(throws: (any Error).self) {
            _ = try yaesu.setSetting(.afGain, to: 256)
        }
        #expect(throws: (any Error).self) {
            _ = try yaesu.setSetting(.breakIn, to: 2)
        }
        #expect(throws: (any Error).self) {
            _ = try yaesu.setSetting(.keyerSpeed, to: 3)
        }
    }

    @Test func kenwoodOnlyKeyerSpeed() throws {
        let dialect = KenwoodDialect.qmx
        for setting in RigSetting.allCases where setting != .keyerSpeed {
            #expect(dialect.readSetting(setting) == nil)
            #expect(dialect.settingRange(setting) == nil)
            #expect(throws: CATBridgeError.unsupportedSetting(setting)) {
                _ = try dialect.setSetting(setting, to: 1)
            }
        }
        let read = try #require(dialect.readSetting(.keyerSpeed))
        #expect(read.wire == "KS;")
        #expect(try dialect.parse(reply: "KS020;", to: read)
                == .setting(.keyerSpeed, 20))
        #expect(try dialect.setSetting(.keyerSpeed, to: 20).wire == "KS020;")
    }
}

@Suite struct MenuDialectTests {
    let yaesu = YaesuDialect.ft891

    @Test func yaesuMenuReadAndSet() throws {
        let read = try yaesu.readMenu(number: "0301")
        #expect(read.wire == "EX0301;")
        #expect(try yaesu.parse(reply: "EX03015;", to: read)
                == .menu(number: "0301", value: "5"))
        #expect(try yaesu.setMenu(number: "0301", value: "5").wire
                == "EX03015;")
        #expect(yaesu.capabilities.contains(.menuAccess))
    }

    @Test func yaesuMenuValidation() {
        #expect(throws: (any Error).self) {
            _ = try yaesu.readMenu(number: "03X1")
        }
        #expect(throws: (any Error).self) {
            _ = try yaesu.readMenu(number: "01")
        }
        #expect(throws: (any Error).self) {
            _ = try yaesu.setMenu(number: "0301", value: "5;EX")
        }
        #expect(throws: (any Error).self) {
            _ = try yaesu.setMenu(number: "0301", value: "")
        }
    }

    @Test func kenwoodHasNoMenuAccess() {
        let dialect = KenwoodDialect.qmx
        #expect(!dialect.capabilities.contains(.menuAccess))
        #expect(throws: CATBridgeError.unsupportedCapability(.menuAccess)) {
            _ = try dialect.readMenu(number: "0301")
        }
    }
}
