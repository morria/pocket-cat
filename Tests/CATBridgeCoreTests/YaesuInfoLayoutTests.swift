// The Yaesu `IF` composite puts a variable-width field between "IF" and
// the frequency: three characters on an FT-891, five on an FTX-1. A fixed
// window therefore reads the wrong nine digits on one radio or the other —
// on a real FTX-1, 14.074 MHz was displayed as 760.140.740.
//
// The parser anchors on the clarifier sign instead. These hold it to that.

import Testing
@testable import CATBridgeCore

@Suite("Yaesu IF layout")
struct YaesuInfoLayoutTests {
    let dialect = YaesuDialect()

    /// "IF" + field(3) + freq(9) + clar(±4) + flags + mode …
    let ft891 = "IF001014074000+00000020000000;"
    /// The same rig state from an FTX-1, whose leading field is five wide.
    let ftx1 = "IF00760014074000+00000020000000;"

    @Test func bothLayoutsYieldTheSameFrequency() throws {
        for reply in [ft891, ftx1] {
            let value = try dialect.parse(reply: reply,
                                          to: CATCommand(wire: "IF;",
                                                         replyPrefix: "IF"))
            guard case .info(let info) = value else {
                Issue.record("expected .info for \(reply)")
                continue
            }
            #expect(info.frequency.hertz == 14_074_000,
                    "wrong frequency from \(reply)")
        }
    }

    @Test func modeIsFoundRelativeToTheSameAnchor() throws {
        for reply in [ft891, ftx1] {
            let value = try dialect.parse(reply: reply,
                                          to: CATCommand(wire: "IF;",
                                                         replyPrefix: "IF"))
            guard case .info(let info) = value else { continue }
            #expect(info.mode == .usb, "wrong mode from \(reply)")
        }
    }

    @Test func negativeClarifierStillAnchors() throws {
        let reply = "IF001014074000-01230020000000;"
        let value = try dialect.parse(reply: reply,
                                      to: CATCommand(wire: "IF;",
                                                     replyPrefix: "IF"))
        guard case .info(let info) = value else {
            Issue.record("expected .info")
            return
        }
        #expect(info.frequency.hertz == 14_074_000)
    }

    @Test func repliesWithNoAnchorAreRejectedRatherThanGuessed() {
        for reply in ["IF001014074000000000;", "IF;", "IF+0000;"] {
            #expect(throws: CATBridgeError.self) {
                _ = try dialect.parse(reply: reply,
                                      to: CATCommand(wire: "IF;",
                                                     replyPrefix: "IF"))
            }
        }
    }

    // MARK: - FA

    @Test func frequencyRepliesAcceptAnyFieldWidth() throws {
        let nine = try dialect.parse(reply: "FA014074000;",
                                     to: CATCommand(wire: "FA;",
                                                    replyPrefix: "FA"))
        let eleven = try dialect.parse(reply: "FA00014074000;",
                                       to: CATCommand(wire: "FA;",
                                                      replyPrefix: "FA"))
        guard case .frequency(let a) = nine,
              case .frequency(let b) = eleven else {
            Issue.record("expected .frequency")
            return
        }
        #expect(a.hertz == 14_074_000)
        #expect(b.hertz == 14_074_000)
    }

    @Test func nonNumericFrequencyRepliesAreRejected() {
        for reply in ["FA01407400X;", "FA;", "FA014074000"] {
            #expect(throws: CATBridgeError.self) {
                _ = try dialect.parse(reply: reply,
                                      to: CATCommand(wire: "FA;",
                                                     replyPrefix: "FA"))
            }
        }
    }
}
