// Which bands this particular QMX has. A QMX is built around one filter
// board, so a given radio covers three or four bands, not the whole HF
// spectrum — and which ones is a property of the unit in front of you.
//
// The radio knows: `Band config.` is a grid with one column per configured
// band, and its `Band name (m)` row says which band each column is. Reading
// that at connect is how the band bar learns what to show.

import CATBridgeKit
import Foundation

/// One column of the radio's `Band config.` table.
public struct SupportedBand: Sendable, Hashable, Identifiable {
    /// Band in metres, as the radio names it — 80, 40, 20…
    public let metres: Int
    /// The column's configured centre frequency, when it reads back.
    /// Preferred over the band plan's default: it is where this radio
    /// actually lands on that band.
    public let centerHz: UInt64?
    /// The grid column, kept so a caller can write back to the right one.
    public let column: Int

    public var id: Int { column }
    /// Matches `Band.title` in the band plan.
    public var bandTitle: String { "\(metres)m" }
}

public enum QMXBandSupport {
    static let menuName = "Band config."
    static let bandRow = "Band name (m)"
    static let centreRow = "Frequency center"

    /// Reads the radio's band table. Returns nil when the menu isn't
    /// laid out as expected — the caller then shows every band rather than
    /// hiding bands the radio might well have.
    public static func read(using client: QMXMenuClient) async throws
        -> [SupportedBand]? {
        let roots = try await client.children()
        guard let config = roots.first(where: {
            $0.name.caseInsensitiveCompare(menuName) == .orderedSame
        }), let columns = config.columns, columns > 0 else { return nil }

        let rows = try await client.children(of: config)
        guard let names = rows.first(where: {
            $0.name.caseInsensitiveCompare(bandRow) == .orderedSame
        }) else { return nil }
        let centres = rows.first {
            $0.name.caseInsensitiveCompare(centreRow) == .orderedSame
        }

        var found: [SupportedBand] = []
        for column in 0..<columns {
            guard let metres = Int(try await client
                .value(of: names, column: column)
                .trimmingCharacters(in: .whitespaces)) else { continue }
            var centre: UInt64?
            if let centres,
               let raw = try? await client.value(of: centres, column: column) {
                centre = UInt64(raw.trimmingCharacters(in: .whitespaces))
            }
            found.append(SupportedBand(metres: metres, centerHz: centre,
                                       column: column))
        }
        return found.isEmpty ? nil : found
    }
}

public extension Array where Element == SupportedBand {
    /// The band-plan entries this radio can reach, in plan order. Bands the
    /// radio lists but the plan doesn't know are dropped — the bar has
    /// nowhere to put them.
    var planBands: [Band] {
        let titles = Set(map(\.bandTitle))
        return BandPlan.all.filter { titles.contains($0.title) }
    }

    func entry(for band: Band) -> SupportedBand? {
        first { $0.bandTitle == band.title }
    }
}
