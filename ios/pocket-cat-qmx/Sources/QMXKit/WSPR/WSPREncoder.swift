// WSPR message encoding: callsign/grid/power → 162 four-level channel
// symbols. Pure arithmetic, no I/O, so it is fully unit-testable.
//
// The chain is the standard one: pack 50 bits, append a 31-bit tail, run a
// rate-1/2 constraint-length-32 convolutional encoder, scramble by
// bit-reversed addressing, then merge with the 162-bit sync vector so that
// symbol = sync + 2 × data.
//
// The sync vector and the two polynomials below were taken from two
// independent published descriptions of the protocol and compared
// byte-for-byte before being committed.

import Foundation

public enum WSPRError: Error, Equatable, Sendable {
    case invalidCallsign(String)
    case invalidGrid(String)
    case invalidPower(Int)
}

public enum WSPREncoder {
    // MARK: - Protocol constants

    public static let symbolCount = 162
    /// 12000 / 8192 Hz — the spacing between adjacent tones.
    public static let toneSpacingHz = 12_000.0 / 8_192.0
    /// 8192 / 12000 s — one symbol. 162 of them is ~110.6 s.
    public static let symbolDuration = 8_192.0 / 12_000.0

    public static let syncVector: [UInt8] = [
        1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0,
        0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1,
        0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1,
        1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1,
        0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0,
        0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
        0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0,
        0, 0,
    ]

    private static let poly1: UInt32 = 0xF2D0_5351
    private static let poly2: UInt32 = 0xE461_3C47

    // MARK: - Public API

    /// The 162 channel symbols (0…3) for a type-1 WSPR message.
    public static func symbols(callsign: String, grid: String,
                               powerDBm: Int) throws -> [UInt8] {
        let packedCall = try packCallsign(callsign)
        let packedGrid = try packGridAndPower(grid: grid, powerDBm: powerDBm)

        // 50 message bits, MSB first: 28 callsign then 22 grid/power.
        var bits: [UInt8] = []
        bits.reserveCapacity(81)
        for shift in stride(from: 27, through: 0, by: -1) {
            bits.append(UInt8((packedCall >> UInt32(shift)) & 1))
        }
        for shift in stride(from: 21, through: 0, by: -1) {
            bits.append(UInt8((packedGrid >> UInt32(shift)) & 1))
        }
        bits.append(contentsOf: repeatElement(0, count: 31)) // encoder tail

        let encoded = convolutionallyEncode(bits)
        let scrambled = interleave(encoded)
        return zip(syncVector, scrambled).map { sync, data in
            sync + 2 * data
        }
    }

    /// Tone for a symbol, relative to the audio base tone.
    public static func toneHz(forSymbol symbol: UInt8,
                              baseHz: Double) -> Double {
        baseHz + Double(symbol) * toneSpacingHz
    }

    // MARK: - Packing

    /// Callsigns pack into 28 bits with the digit in the third position;
    /// short prefixes shift right by one (`K1ABC` → `" K1ABC"`).
    public static func normalizeCallsign(_ raw: String) throws -> String {
        let trimmed = raw.uppercased()
            .trimmingCharacters(in: .whitespaces)
        guard (3...6).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber })
        else { throw WSPRError.invalidCallsign(raw) }

        var call = trimmed
        let characters = Array(call)
        if !characters[2].isNumber {
            guard characters[1].isNumber else {
                throw WSPRError.invalidCallsign(raw)
            }
            call = " " + call
        }
        guard Array(call)[2].isNumber, call.count <= 6 else {
            throw WSPRError.invalidCallsign(raw)
        }
        return call.padding(toLength: 6, withPad: " ", startingAt: 0)
    }

    static func packCallsign(_ raw: String) throws -> UInt32 {
        let call = Array(try normalizeCallsign(raw))
        func alphanumeric(_ character: Character) -> UInt32? {
            if character.isNumber {
                return UInt32(character.wholeNumberValue!)
            }
            if character.isLetter, let ascii = character.asciiValue {
                return UInt32(ascii - 65) + 10
            }
            return character == " " ? 36 : nil
        }
        func letterOrSpace(_ character: Character) -> UInt32? {
            if character == " " { return 0 }
            guard character.isLetter, let ascii = character.asciiValue
            else { return nil }
            return UInt32(ascii - 65) + 1
        }

        guard let c0 = alphanumeric(call[0]), c0 <= 36,
              let c1 = alphanumeric(call[1]), c1 <= 35,
              let c2 = alphanumeric(call[2]), c2 <= 9,
              let c3 = letterOrSpace(call[3]),
              let c4 = letterOrSpace(call[4]),
              let c5 = letterOrSpace(call[5])
        else { throw WSPRError.invalidCallsign(raw) }

        var n = c0
        n = n * 36 + c1
        n = n * 10 + c2
        n = n * 27 + c3
        n = n * 27 + c4
        n = n * 27 + c5
        return n
    }

    static func packGridAndPower(grid: String,
                                 powerDBm: Int) throws -> UInt32 {
        guard (0...60).contains(powerDBm) else {
            throw WSPRError.invalidPower(powerDBm)
        }
        let field = Array(grid.uppercased().trimmingCharacters(in: .whitespaces))
        guard field.count == 4,
              let a = field[0].asciiValue, ("A"..."R").contains(field[0]),
              let b = field[1].asciiValue, ("A"..."R").contains(field[1]),
              field[2].isNumber, field[3].isNumber
        else { throw WSPRError.invalidGrid(grid) }

        let lon = UInt32(a - 65)
        let lat = UInt32(b - 65)
        let lonDigit = UInt32(field[2].wholeNumberValue!)
        let latDigit = UInt32(field[3].wholeNumberValue!)

        let m1 = 179 - 10 * lon - lonDigit
        let m2 = 10 * lat + latDigit
        return (m1 * 180 + m2) * 128 + UInt32(powerDBm) + 64
    }

    /// Inverse of the two packers — the round trip is what the tests use to
    /// prove the field arithmetic, since no on-air reference is available
    /// here.
    static func unpack(callsign packed: UInt32) -> String {
        var n = packed
        func take(_ modulus: UInt32) -> UInt32 {
            let value = n % modulus
            n /= modulus
            return value
        }
        let c5 = take(27), c4 = take(27), c3 = take(27)
        let c2 = take(10), c1 = take(36), c0 = take(37)

        func alphanumeric(_ value: UInt32) -> Character {
            if value < 10 { return Character(String(value)) }
            if value < 36 {
                return Character(UnicodeScalar(UInt8(value - 10 + 65)))
            }
            return " "
        }
        func letterOrSpace(_ value: UInt32) -> Character {
            value == 0 ? " "
                       : Character(UnicodeScalar(UInt8(value - 1 + 65)))
        }
        return String([alphanumeric(c0), alphanumeric(c1), alphanumeric(c2),
                       letterOrSpace(c3), letterOrSpace(c4),
                       letterOrSpace(c5)])
    }

    static func unpack(gridPower packed: UInt32) -> (grid: String,
                                                     powerDBm: Int) {
        let power = Int(packed % 128) - 64
        let m = packed / 128
        let m1 = m / 180
        let m2 = m % 180
        let lon = (179 - m1) / 10
        let lonDigit = (179 - m1) % 10
        let lat = m2 / 10
        let latDigit = m2 % 10
        let grid = String([
            Character(UnicodeScalar(UInt8(lon + 65))),
            Character(UnicodeScalar(UInt8(lat + 65))),
            Character(String(lonDigit)),
            Character(String(latDigit)),
        ])
        return (grid, power)
    }

    // MARK: - FEC

    private static func convolutionallyEncode(_ bits: [UInt8]) -> [UInt8] {
        var register: UInt32 = 0
        var out: [UInt8] = []
        out.reserveCapacity(bits.count * 2)
        for bit in bits {
            register = (register << 1) | UInt32(bit)
            out.append(parity(register & poly1))
            out.append(parity(register & poly2))
        }
        return out
    }

    private static func parity(_ value: UInt32) -> UInt8 {
        UInt8(value.nonzeroBitCount & 1)
    }

    /// Bit-reversed addressing: walk 0…255, and whenever the reversed
    /// address lands inside the frame, take the next source bit.
    private static func interleave(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: symbolCount)
        var source = 0
        for address in 0..<256 {
            let reversed = Int(reverseBits(UInt8(address)))
            guard reversed < symbolCount else { continue }
            out[reversed] = bits[source]
            source += 1
            if source == symbolCount { break }
        }
        return out
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}
