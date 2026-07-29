// Morse timing, used to tell the operator how long a message will take on
// the air before they key it.
//
// `KY` is buffered — the radio sends at its own keyer speed and gives no
// completion signal — so an estimate is the only way to know whether a
// message is a two-second exchange or a thirty-second monologue.
//
// Units are standard: dit 1, dah 3, intra-character gap 1, inter-character
// gap 3, word gap 7. "PARIS" plus its trailing word gap is 50 units, which
// is the definition of words-per-minute.

import Foundation

public enum CWTiming {
    /// Element patterns for everything `CWText.allowed` admits.
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".",
        "F": "..-.", "G": "--.", "H": "....", "I": "..", "J": ".---",
        "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---",
        "P": ".--.", "Q": "--.-", "R": ".-.", "S": "...", "T": "-",
        "U": "..-", "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--",
        "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--",
        "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.",
        "!": "-.-.--", "/": "-..-.", "(": "-.--.", ")": "-.--.-",
        "&": ".-...", ":": "---...", "+": ".-.-.", "-": "-....-",
        "=": "-...-", "@": ".--.-.", "\"": ".-..-.",
    ]

    /// Units for one character, gaps between its own elements included.
    static func units(forCharacter character: Character) -> Int {
        guard let pattern = table[character] else { return 0 }
        let elements = pattern.reduce(0) { $0 + ($1 == "-" ? 3 : 1) }
        return elements + max(0, pattern.count - 1)
    }

    /// Units for a whole message: characters joined by 3, words by 7. No
    /// trailing word gap — the message ends when the last element does.
    public static func units(_ text: String) -> Int {
        let words = text.uppercased().split(separator: " ")
        var total = 0
        for (index, word) in words.enumerated() {
            if index > 0 { total += 7 }
            var first = true
            for character in word {
                let value = units(forCharacter: character)
                guard value > 0 else { continue }
                if !first { total += 3 }
                total += value
                first = false
            }
        }
        return total
    }

    /// How long the radio will be transmitting, at its keyer speed.
    public static func seconds(_ text: String, wpm: Int) -> Double {
        guard wpm > 0 else { return 0 }
        return Double(units(text)) * (1.2 / Double(wpm))
    }
}
