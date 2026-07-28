// Morse timing, template expansion and callsign spotting — the logic
// behind the CW compose bar, kept out of the view so it can be tested.

import Foundation
import Testing
@testable import QMXKit

@Suite("CW timing")
struct CWTimingTests {
    /// PARIS plus its trailing word gap is 50 units — that identity *is*
    /// the definition of words per minute, so it anchors everything else.
    @Test func parisIsTheWPMYardstick() {
        #expect(CWTiming.units("PARIS") == 43)          // without word gap
        #expect(CWTiming.units("PARIS PARIS") == 93)    // 43 + 7 + 43
        // 43 + 7 = 50 units at 20 WPM = exactly 3 seconds a word.
        let word = Double(43 + 7) * (1.2 / 20.0)
        #expect(abs(word - 3.0) < 0.0001)
    }

    @Test func elementCountsMatchTheStandard() {
        #expect(CWTiming.units("E") == 1)       // one dit
        #expect(CWTiming.units("T") == 3)       // one dah
        #expect(CWTiming.units("A") == 5)       // dit gap dah
        #expect(CWTiming.units("EE") == 5)      // dit, 3 gap, dit
        #expect(CWTiming.units("E E") == 9)     // dit, 7 gap, dit
    }

    @Test func speedScalesTheDuration() {
        let slow = CWTiming.seconds("CQ CQ", wpm: 10)
        let fast = CWTiming.seconds("CQ CQ", wpm: 20)
        #expect(abs(slow - 2 * fast) < 0.0001)
    }

    @Test func unknownCharactersCostNothing() {
        #expect(CWTiming.units("~") == 0)
        #expect(CWTiming.seconds("", wpm: 20) == 0)
        #expect(CWTiming.seconds("CQ", wpm: 0) == 0)
    }

    @Test func everySendableCharacterHasATiming() {
        for character in CWText.allowed where character != " " {
            #expect(CWTiming.units(String(character)) > 0,
                    "no Morse pattern for \(character)")
        }
    }
}

@Suite("CW templates")
struct CWTemplateTests {
    let station = StationIdentity(callsign: "M0ABC", name: "ANDREW",
                                  qth: "LONDON", grid: "IO91")

    @Test func placeholdersFillFromTheStation() {
        let expanded = station.expand("CQ CQ DE {CALL} {CALL} K")
        #expect(expanded.text == "CQ CQ DE M0ABC M0ABC K")
        #expect(expanded.missing.isEmpty)
    }

    @Test func theirCallFillsWhenSupplied() {
        let expanded = station.expand("{THEIRCALL} DE {CALL} K",
                                      theirCall: "G0XYZ")
        #expect(expanded.text == "G0XYZ DE M0ABC K")
        #expect(expanded.missing.isEmpty)
    }

    @Test func emptyFieldsAreReportedRatherThanKeyedBlank() {
        let bare = StationIdentity(callsign: "M0ABC")
        let expanded = bare.expand("OP {NAME} QTH {QTH}")
        #expect(expanded.missing == ["NAME", "QTH"])
        #expect(StationIdentity.describe(expanded.missing)
                == "your name, your location")
    }

    @Test func expansionUppercasesForTheKeyer() {
        let lower = StationIdentity(callsign: "m0abc")
        #expect(lower.expand("de {CALL}").text == "DE M0ABC")
    }

    @Test func everyDefaultTemplateSurvivesAFullStation() {
        for template in CWTemplate.defaults {
            let expanded = station.expand(template.text, theirCall: "G0XYZ")
            #expect(expanded.missing.isEmpty, "\(template.label) incomplete")
            // And everything it produces must be keyable.
            let (text, dropped) = CWText.normalize(expanded.text)
            #expect(dropped.isEmpty, "\(template.label) has unsendable characters")
            #expect(!text.isEmpty)
        }
    }

    @Test func templatesNeedingAStationAreFlagged() {
        #expect(CWTemplate.defaults.first { $0.label == "Reply" }?
            .needsTheirCall == true)
        #expect(CWTemplate.defaults.first { $0.label == "CQ" }?
            .needsTheirCall == false)
    }
}

@Suite("Callsign spotting")
struct CallsignSpotterTests {
    @Test func findsCallsignsInDecodedCopy() {
        #expect(CallsignSpotter.callsigns(in: "CQ CQ DE G0XYZ G0XYZ K")
                == ["G0XYZ"])
        #expect(CallsignSpotter.callsigns(in: "M0ABC DE 2E0AAA/P KN")
                == ["M0ABC", "2E0AAA/P"])
    }

    /// A decoder produces noise; a chip that tunes you at a hallucinated
    /// station is worse than no chip.
    @Test func ignoresReportsAndNoise() {
        #expect(CallsignSpotter.callsigns(in: "UR RST 599 599 TU").isEmpty)
        #expect(CallsignSpotter.callsigns(in: "EEE TTT ...").isEmpty)
        #expect(CallsignSpotter.callsigns(in: "73").isEmpty)
    }

    @Test func recentsAreNewestFirstAndExcludeMe() {
        let heard = ["CQ DE G0XYZ K", "M0ABC DE W1AW K",
                     "M0ABC DE G0XYZ 599"]
        let recents = CallsignSpotter.recentCallsigns(in: heard,
                                                      excluding: "M0ABC")
        #expect(recents == ["G0XYZ", "W1AW"])
    }

    @Test func recentsAreCapped() {
        let heard = (0..<10).map { "DE G\($0)ABC K" }
        #expect(CallsignSpotter.recentCallsigns(in: heard, excluding: "M0ABC",
                                                limit: 3).count == 3)
    }
}
