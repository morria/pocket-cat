// The FT-891's SH width tables as data (docs/passband.md §2.2, researched
// from Hamlib's shared FT-891/991 tables — yaesu-cat-ft891.md "Passband
// commands"). Index 0 is the rig default and is never written by the app.

import CATBridgeKit

public enum PassbandTables {
    /// One mode family's width list. `widths[i]` is the bandwidth in Hz for
    /// SH index `i`; index 0 is a placeholder for "rig default".
    public struct WidthFamily: Sendable, Equatable {
        public let widths: [Int]
        /// Widths ≤ this require narrow mode (`NA01;`) before `SH`.
        public let narrowMax: Int

        public var indices: Range<Int> { 1..<widths.count }

        /// Smallest index whose width is ≥ hz (Hamlib semantics); clamps
        /// to the widest.
        public func index(forWidthHz hz: Int) -> Int {
            for i in 1..<widths.count where hz <= widths[i] {
                return i
            }
            return widths.count - 1
        }

        public func widthHz(at index: Int) -> Int? {
            guard indices.contains(index) else { return nil }
            return widths[index]
        }

        public func requiresNarrow(index: Int) -> Bool {
            widthHz(at: index).map { $0 <= narrowMax } ?? false
        }
    }

    /// CW / RTTY / DATA share one table.
    public static let cwFamily = WidthFamily(
        widths: [0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500,
                 800, 1200, 1400, 1700, 2000, 2400, 3000],
        narrowMax: 500)

    public static let ssbFamily = WidthFamily(
        widths: [0, 200, 400, 600, 850, 1100, 1350, 1500, 1650, 1800,
                 1950, 2100, 2200, 2300, 2400, 2500, 2600, 2700, 2800,
                 2900, 3000, 3200],
        narrowMax: 1800)

    /// nil for modes with no `SH` (AM/FM: width is the NA toggle only).
    public static func family(for mode: OperatingMode) -> WidthFamily? {
        switch mode {
        case .lsb, .usb:
            return ssbFamily
        case .cw, .cwReverse, .rtty, .rttyReverse, .dataLSB, .dataUSB:
            return cwFamily
        default:
            return nil
        }
    }

    /// Modes where IS/BP/CO apply at all (assume rejected in AM/FM —
    /// docs/passband.md §2.1 BENCH row; the UI disables there regardless).
    public static func supportsPassband(_ mode: OperatingMode) -> Bool {
        family(for: mode) != nil
    }

    // Ranges (yaesu-cat-ft891.md "Passband commands").
    public static let shiftRangeHz = -1200...1200
    /// Panel steps 20 Hz; CAT rounding unverified — we snap ourselves.
    public static let shiftStepHz = 20
    public static let notchRangeHz = 10...3200
    public static let notchStepHz = 10
    public static let contourRangeHz = 10...3200
}
