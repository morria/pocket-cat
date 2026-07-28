// Maidenhead conversion. Grids are what WSPR carries and what CW templates
// announce, so a wrong one is broadcast rather than merely displayed.

import Foundation
import Testing
@testable import QMXKit

@Suite("Maidenhead")
struct MaidenheadTests {
    @Test(arguments: [
        (51.5074, -0.1278, "IO91wm"),    // London
        (40.7128, -74.0060, "FN20xr"),   // New York
        (-33.8688, 151.2093, "QF56od"),  // Sydney
        (0.0, 0.0, "JJ00aa"),            // the origin corner
    ])
    func knownPlacesConvert(_ place: (lat: Double, lon: Double,
                                      grid: String)) {
        #expect(Maidenhead.locator(latitude: place.lat,
                                   longitude: place.lon) == place.grid)
    }

    @Test func precisionTruncatesToFieldOrSquare() {
        #expect(Maidenhead.locator(latitude: 51.5074, longitude: -0.1278,
                                   precision: 2) == "IO")
        #expect(Maidenhead.locator(latitude: 51.5074, longitude: -0.1278,
                                   precision: 4) == "IO91")
    }

    @Test func extremesStayInsideTheGrid() {
        // Clamped rather than overflowing past 'R'.
        let northPole = Maidenhead.locator(latitude: 90, longitude: 180)
        #expect(Maidenhead.isValid(northPole))
        let southPole = Maidenhead.locator(latitude: -90, longitude: -180)
        #expect(southPole.hasPrefix("AA"))
    }

    @Test func validationAcceptsFourAndSixAndRejectsJunk() {
        #expect(Maidenhead.isValid("IO91"))
        #expect(Maidenhead.isValid("IO91wm"))
        #expect(Maidenhead.isValid("io91wm"))
        #expect(!Maidenhead.isValid("IO9"))
        #expect(!Maidenhead.isValid("ZZ91"))    // letters past R
        #expect(!Maidenhead.isValid("IO9A"))    // digits required
        #expect(!Maidenhead.isValid(""))
    }

    /// WSPR type-1 messages carry four characters, so the square is what
    /// the beacon must send even when the operator stored six.
    @Test func squareTakesWhatWSPRNeeds() {
        #expect(Maidenhead.square("IO91wm") == "IO91")
        #expect(Maidenhead.square("io91") == "IO91")
        // And the result must survive the WSPR packer.
        #expect(throws: Never.self) {
            try WSPREncoder.symbols(callsign: "M0ABC",
                                    grid: Maidenhead.square("IO91wm"),
                                    powerDBm: 23)
        }
    }

    @Test func everyGeneratedSquareIsWSPRSendable() throws {
        // A sweep of the globe: whatever GPS returns must be encodable.
        for lat in stride(from: -80.0, through: 80.0, by: 20) {
            for lon in stride(from: -180.0, through: 160.0, by: 40) {
                let grid = Maidenhead.square(
                    Maidenhead.locator(latitude: lat, longitude: lon))
                #expect(throws: Never.self) {
                    try WSPREncoder.symbols(callsign: "M0ABC", grid: grid,
                                            powerDBm: 23)
                }
            }
        }
    }
}

@Suite("WSPR configuration gate")
struct WSPRConfigurationTests {
    @MainActor
    func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(
            suiteName: "test.\(UUID().uuidString)")!)
    }

    /// GPS fills six characters and WSPR carries four. Checking the raw
    /// grid refused a perfectly good locator and greyed out Start Beacon.
    @Test @MainActor func aSixCharacterGridIsAcceptable() {
        let s = settings()
        s.callsign = "M0ABC"
        s.grid = "IO91wm"
        #expect(s.wsprIsConfigured)
    }

    @Test @MainActor func fourCharacterGridsStillWork() {
        let s = settings()
        s.callsign = "M0ABC"
        s.grid = "IO91"
        #expect(s.wsprIsConfigured)
    }

    @Test @MainActor func incompleteOrJunkStationsAreRefused() {
        let s = settings()
        #expect(!s.wsprIsConfigured)          // nothing set

        s.callsign = "M0ABC"
        #expect(!s.wsprIsConfigured)          // no grid

        s.grid = "NOTAGRID"
        #expect(!s.wsprIsConfigured)

        s.grid = "IO91"
        s.callsign = "NOTACALL"
        #expect(!s.wsprIsConfigured)
    }

    @Test @MainActor func surroundingWhitespaceIsForgiven() {
        let s = settings()
        s.callsign = " M0ABC "
        s.grid = "IO91wm"
        #expect(s.wsprIsConfigured)
    }
}
