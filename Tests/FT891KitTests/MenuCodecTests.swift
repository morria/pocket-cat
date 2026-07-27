// Codec behavior: engineering value ↔ wire digits, including the signed
// items' mandatory sign (and `-00`/`+00` zero forms) and index coding.

import Testing
@testable import FT891Kit

@Suite("Menu value codecs")
struct MenuCodecTests {
    private let numberItem = MenuItem(
        id: "01-01", group: .agc, officialName: "AGC FAST DELAY",
        friendlyName: "AGC fast decay time", summary: "test",
        kind: .number(20...4000, step: 20, unit: "ms"),
        digits: 4, defaultValue: 300)

    private let signedItem = MenuItem(
        id: "12-02", group: .rxDSP, officialName: "IF SHIFT",
        friendlyName: "IF shift", summary: "test",
        kind: .signedNumber(-1200...1200, step: 20, unit: "Hz"),
        digits: 4, defaultValue: 0)

    private let optionsItem = MenuItem(
        id: "05-06", group: .general, officialName: "CAT RATE",
        friendlyName: "CAT baud rate", summary: "test",
        kind: .options(["4800 bps", "9600 bps", "19200 bps", "38400 bps"]),
        digits: 1, defaultValue: 0)

    @Test func numberEncoding() throws {
        #expect(try numberItem.encode(300) == "0300")
        #expect(try numberItem.encode(4000) == "4000")
        #expect(try numberItem.decode("0020") == 20)
        #expect(throws: MenuItem.CodecError.self) {
            try numberItem.encode(5000)
        }
        #expect(throws: MenuItem.CodecError.self) {
            try numberItem.decode("9999")
        }
    }

    @Test func signedEncoding() throws {
        #expect(try signedItem.encode(-1200) == "-1200")
        #expect(try signedItem.encode(40) == "+0040")
        #expect(try signedItem.encode(0) == "+0000")
        #expect(try signedItem.decode("-0020") == -20)
        #expect(try signedItem.decode("+0000") == 0)
        #expect(try signedItem.decode("-0000") == 0) // radio may send -0
        #expect(throws: MenuItem.CodecError.self) {
            try signedItem.decode("0020") // sign is mandatory
        }
    }

    @Test func decodeToleratesUnexpectedZeroPadding() throws {
        // Hardware reality: the rig may answer wider than the CAT book's
        // digit column (EX1302 answers "03" where the book says 1 digit).
        #expect(try optionsItem.decode("03") == 3)
        #expect(try numberItem.decode("00300") == 300)
        #expect(try signedItem.decode("-020") == -20)
        #expect(throws: MenuItem.CodecError.self) {
            try optionsItem.decode("") // empty is still malformed
        }
        #expect(throws: MenuItem.CodecError.self) {
            try optionsItem.decode("07") // in-width but out of range
        }
    }

    @Test func optionsEncoding() throws {
        #expect(try optionsItem.encode(3) == "3")
        #expect(try optionsItem.decode("0") == 0)
        #expect(optionsItem.label(for: 3) == "38400 bps")
        #expect(throws: MenuItem.CodecError.self) {
            try optionsItem.encode(4)
        }
    }

    @Test func sharedEncodingTables() {
        if case let .options(labels) = SharedEncoding.lcut {
            #expect(labels.count == 20) // OFF + 100…1000 in 50 Hz steps
            #expect(labels[0] == "OFF")
            #expect(labels[1] == "100 Hz")
            #expect(labels[19] == "1000 Hz")
        } else {
            Issue.record("lcut should be options")
        }
        if case let .options(labels) = SharedEncoding.hcut {
            #expect(labels.count == 68) // OFF + 700…4000 in 50 Hz steps
            #expect(labels[67] == "4000 Hz")
        } else {
            Issue.record("hcut should be options")
        }
    }

    @Test func catalogRoundTripsEveryItem() throws {
        for item in MenuCatalog.items {
            let range = item.kind.range
            for value in [range.lowerBound, item.defaultValue,
                          range.upperBound] {
                let wire = try item.encode(value)
                #expect(try item.decode(wire) == value,
                        "\(item.id) failed round-trip at \(value)")
                let expectedLength = item.digits + (item.isSigned ? 1 : 0)
                #expect(wire.count == expectedLength,
                        "\(item.id) wire \(wire) ≠ \(expectedLength) chars")
            }
        }
    }
}
