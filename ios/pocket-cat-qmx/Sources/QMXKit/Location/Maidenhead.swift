// Maidenhead locators, and a one-shot fix from CoreLocation.
//
// The operator's grid is needed by WSPR (four characters) and by CW
// templates (six reads better on the air), so this produces six and lets
// callers take the prefix they need.

import Foundation

public enum Maidenhead {
    /// Six-character locator, e.g. `IO91wm`. Fields and squares upper-case,
    /// sub-squares lower-case, as the convention has it.
    public static func locator(latitude: Double, longitude: Double,
                               precision: Int = 6) -> String {
        let lon = min(max(longitude, -180), 179.999_999) + 180
        let lat = min(max(latitude, -90), 89.999_999) + 90

        let fieldLon = Int(lon / 20)
        let fieldLat = Int(lat / 10)
        var out = String(UnicodeScalar(UInt8(65 + fieldLon)))
            + String(UnicodeScalar(UInt8(65 + fieldLat)))
        if precision <= 2 { return out }

        let squareLon = Int(lon.truncatingRemainder(dividingBy: 20) / 2)
        let squareLat = Int(lat.truncatingRemainder(dividingBy: 10))
        out += "\(squareLon)\(squareLat)"
        if precision <= 4 { return out }

        let subLon = Int(lon.truncatingRemainder(dividingBy: 2) * 12)
        let subLat = Int(lat.truncatingRemainder(dividingBy: 1) * 24)
        out += String(UnicodeScalar(UInt8(97 + subLon)))
            + String(UnicodeScalar(UInt8(97 + subLat)))
        return out
    }

    /// True when the string is a usable locator — two letters A–R, two
    /// digits, and optionally a sub-square pair.
    public static func isValid(_ locator: String) -> Bool {
        let text = locator.uppercased()
        guard text.count == 4 || text.count == 6 else { return false }
        let characters = Array(text)
        guard ("A"..."R").contains(characters[0]),
              ("A"..."R").contains(characters[1]),
              characters[2].isNumber, characters[3].isNumber
        else { return false }
        guard text.count == 6 else { return true }
        return ("A"..."X").contains(characters[4])
            && ("A"..."X").contains(characters[5])
    }

    /// The four-character square a locator sits in — what WSPR carries.
    public static func square(_ locator: String) -> String {
        String(locator.uppercased().prefix(4))
    }
}
