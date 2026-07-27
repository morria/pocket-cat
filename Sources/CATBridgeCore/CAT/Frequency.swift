// Typed frequency. Integer hertz at the core: CAT is integer-Hz on the wire
// and Double cannot represent common dial frequencies (14.250 MHz) exactly.

public struct Frequency: Sendable, Equatable, Hashable, Comparable,
    CustomStringConvertible {
    public let hertz: UInt64

    public init(hz: UInt64) { self.hertz = hz }

    /// Convenience that rounds to the nearest hertz.
    public static func kilohertz(_ value: Double) -> Frequency {
        Frequency(hz: UInt64((value * 1_000).rounded()))
    }

    /// Convenience that rounds to the nearest hertz.
    public static func megahertz(_ value: Double) -> Frequency {
        Frequency(hz: UInt64((value * 1_000_000).rounded()))
    }

    public var megahertzValue: Double { Double(hertz) / 1_000_000 }

    public static func < (lhs: Frequency, rhs: Frequency) -> Bool {
        lhs.hertz < rhs.hertz
    }

    public var description: String {
        let mhz = hertz / 1_000_000
        let rest = hertz % 1_000_000
        let khz = rest / 1_000
        let hz = rest % 1_000
        return String(format: "%d.%03d.%03d MHz", mhz, khz, hz)
    }

    /// Zero-padded decimal digits, as CAT frequency fields require.
    /// Returns nil if the value does not fit the field width.
    public func catDigits(width: Int) -> String? {
        let s = String(hertz)
        guard s.count <= width else { return nil }
        return String(repeating: "0", count: width - s.count) + s
    }
}
