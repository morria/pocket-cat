// Band plan, band-stacking registers, saved memories and automatic
// recents — all device-side, so none of it depends on the radio having
// memory support (docs/rig-control-ux.md §4).

import CATBridgeKit
import Foundation
import Observation

// MARK: - Band plan

public struct BandSegment: Sendable, Hashable, Identifiable {
    public let name: String
    public let hz: UInt64
    public var id: String { "\(name)-\(hz)" }
}

/// A band, its extent, and the frequencies people actually call on.
///
/// `range` is used only to work out which band a frequency is in — band
/// *edges* differ by region and licence, so nothing here is authoritative
/// for transmit legality. The segments are common activity frequencies,
/// not rules.
public struct Band: Identifiable, Sendable, Hashable {
    public let title: String
    public let range: ClosedRange<UInt64>
    public let segments: [BandSegment]
    /// The radio's own `BS` band code, when it has one.
    public let catBand: FT891Band?

    public var id: String { title }
    public var defaultHz: UInt64 { segments.first?.hz ?? range.lowerBound }
}

public enum BandPlan {
    public static let all: [Band] = [
        Band(title: "160m", range: 1_800_000...2_000_000,
             segments: [BandSegment(name: "CW", hz: 1_820_000),
                        BandSegment(name: "FT8", hz: 1_840_000),
                        BandSegment(name: "SSB", hz: 1_910_000)],
             catBand: .m160),
        Band(title: "80m", range: 3_500_000...4_000_000,
             segments: [BandSegment(name: "CW", hz: 3_560_000),
                        BandSegment(name: "FT8", hz: 3_573_000),
                        BandSegment(name: "SSB", hz: 3_700_000)],
             catBand: .m80),
        Band(title: "40m", range: 7_000_000...7_300_000,
             segments: [BandSegment(name: "CW", hz: 7_030_000),
                        BandSegment(name: "FT8", hz: 7_074_000),
                        BandSegment(name: "SSB", hz: 7_150_000)],
             catBand: .m40),
        Band(title: "30m", range: 10_100_000...10_150_000,
             segments: [BandSegment(name: "CW", hz: 10_115_000),
                        BandSegment(name: "FT8", hz: 10_136_000)],
             catBand: .m30),
        Band(title: "20m", range: 14_000_000...14_350_000,
             segments: [BandSegment(name: "CW", hz: 14_060_000),
                        BandSegment(name: "FT8", hz: 14_074_000),
                        BandSegment(name: "SSB", hz: 14_250_000)],
             catBand: .m20),
        Band(title: "17m", range: 18_068_000...18_168_000,
             segments: [BandSegment(name: "CW", hz: 18_080_000),
                        BandSegment(name: "FT8", hz: 18_100_000),
                        BandSegment(name: "SSB", hz: 18_130_000)],
             catBand: .m17),
        Band(title: "15m", range: 21_000_000...21_450_000,
             segments: [BandSegment(name: "CW", hz: 21_060_000),
                        BandSegment(name: "FT8", hz: 21_074_000),
                        BandSegment(name: "SSB", hz: 21_300_000)],
             catBand: .m15),
        Band(title: "12m", range: 24_890_000...24_990_000,
             segments: [BandSegment(name: "CW", hz: 24_900_000),
                        BandSegment(name: "FT8", hz: 24_915_000),
                        BandSegment(name: "SSB", hz: 24_950_000)],
             catBand: .m12),
        Band(title: "10m", range: 28_000_000...29_700_000,
             segments: [BandSegment(name: "CW", hz: 28_060_000),
                        BandSegment(name: "FT8", hz: 28_074_000),
                        BandSegment(name: "SSB", hz: 28_400_000)],
             catBand: .m10),
        Band(title: "6m", range: 50_000_000...54_000_000,
             segments: [BandSegment(name: "CW", hz: 50_090_000),
                        BandSegment(name: "FT8", hz: 50_313_000),
                        BandSegment(name: "SSB", hz: 50_150_000)],
             catBand: .m6),
    ]

    public static func band(containing hz: UInt64) -> Band? {
        all.first { $0.range.contains(hz) }
    }
}

// MARK: - Stored entries

public struct MemoryChannel: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var hz: UInt64
    /// Stored as a stable token so the file survives enum changes.
    public var modeToken: String?
    public var date: Date

    public init(id: UUID = UUID(), name: String, hz: UInt64,
                mode: OperatingMode? = nil, date: Date = Date()) {
        self.id = id
        self.name = name
        self.hz = hz
        self.modeToken = mode.flatMap(ModeToken.token)
        self.date = date
    }

    public var frequency: Frequency { Frequency(hz: hz) }
    public var mode: OperatingMode? { modeToken.flatMap(ModeToken.mode) }
    public var band: Band? { BandPlan.band(containing: hz) }

    /// "14.074 00" — grouped for reading at a glance.
    public var displayFrequency: String {
        let mhz = Double(hz) / 1_000_000
        return String(format: "%.5f MHz", mhz)
    }
}

/// A stable string for each mode: `OperatingMode` has no raw value, and a
/// stored file should not depend on case order.
enum ModeToken {
    private static let table: [(OperatingMode, String)] = [
        (.lsb, "lsb"), (.usb, "usb"), (.cw, "cw"), (.cwReverse, "cw-r"),
        (.fm, "fm"), (.fmNarrow, "fm-n"), (.am, "am"), (.amNarrow, "am-n"),
        (.rtty, "rtty"), (.rttyReverse, "rtty-r"), (.dataLSB, "data-lsb"),
        (.dataUSB, "data-usb"), (.dataFM, "data-fm"),
        (.dataFMNarrow, "data-fm-n"), (.c4fm, "c4fm"),
    ]

    static func token(_ mode: OperatingMode) -> String? {
        table.first { $0.0 == mode }?.1
    }

    static func mode(_ token: String) -> OperatingMode? {
        table.first { $0.1 == token }?.0
    }
}

// MARK: - Store

/// Saved memories, per-band stacking registers, and automatic recents.
/// Persisted as JSON in `UserDefaults` — small, synchronous, and good
/// enough for a few hundred entries.
@MainActor
@Observable
public final class StationMemory {
    public static let shared = StationMemory()

    /// Frequencies the operator chose to keep, newest first within a band.
    public private(set) var channels: [MemoryChannel] = []
    /// Where they have actually been, most recent first. No naming, no
    /// decisions — the Phone-app Recents model.
    public private(set) var recents: [MemoryChannel] = []

    /// Last frequency used on each band, keyed by band title.
    private var stack: [String: MemoryChannel] = [:]

    public static let recentsLimit = 12
    /// Visits closer together than this are treated as the same spot, so
    /// tuning through a band doesn't fill the list.
    public static let recentsResolutionHz: UInt64 = 500

    private let defaults: UserDefaults
    private enum Key {
        static let channels = "ft891.memories"
        static let stack = "ft891.bandStack"
        static let recents = "ft891.recents"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        channels = Self.load([MemoryChannel].self, Key.channels,
                             from: defaults) ?? []
        recents = Self.load([MemoryChannel].self, Key.recents,
                            from: defaults) ?? []
        stack = Self.load([String: MemoryChannel].self, Key.stack,
                          from: defaults) ?? [:]
    }

    // MARK: Band stack

    /// What tapping this band's chip should tune to, if we've been there.
    public func stackEntry(for band: Band) -> MemoryChannel? {
        stack[band.title]
    }

    /// Records where the radio just landed: updates the band's register and
    /// the recents list. Cheap enough to call on every settled tune.
    public func noteVisit(hz: UInt64, mode: OperatingMode?) {
        guard let band = BandPlan.band(containing: hz) else { return }
        let entry = MemoryChannel(name: band.title, hz: hz, mode: mode)
        stack[band.title] = entry
        persistStack()

        // Collapse a run of small moves into one recent.
        if let first = recents.first, first.hz.distance(to: hz).magnitude
            < Self.recentsResolutionHz {
            recents[0] = entry
        } else {
            recents.removeAll { $0.hz == hz }
            recents.insert(entry, at: 0)
            if recents.count > Self.recentsLimit {
                recents.removeLast(recents.count - Self.recentsLimit)
            }
        }
        persistRecents()
    }

    public func clearRecents() {
        recents.removeAll()
        persistRecents()
    }

    // MARK: Memories

    @discardableResult
    public func store(hz: UInt64, mode: OperatingMode?,
                      name: String? = nil) -> MemoryChannel {
        let channel = MemoryChannel(
            name: name?.isEmpty == false ? name! : Self.suggestedName(for: hz),
            hz: hz, mode: mode)
        channels.insert(channel, at: 0)
        persistChannels()
        return channel
    }

    public func rename(_ id: MemoryChannel.ID, to name: String) {
        guard let index = channels.firstIndex(where: { $0.id == id })
        else { return }
        channels[index].name = name
        persistChannels()
    }

    public func delete(_ id: MemoryChannel.ID) {
        channels.removeAll { $0.id == id }
        persistChannels()
    }

    /// Reorder, without depending on SwiftUI's `move` — this layer has no
    /// UI framework in it.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { index in
            channels.indices.contains(index) ? channels[index] : nil
        }
        guard !moving.isEmpty else { return }
        let insertAt = destination - source.filter { $0 < destination }.count
        var remaining = channels.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        remaining.insert(contentsOf: moving,
                         at: min(max(0, insertAt), remaining.count))
        channels = remaining
        persistChannels()
    }

    /// Memories grouped by band, bands in plan order, unknown bands last.
    public var channelsByBand: [(band: String, channels: [MemoryChannel])] {
        let grouped = Dictionary(grouping: channels) {
            $0.band?.title ?? "Other"
        }
        let order = BandPlan.all.map(\.title) + ["Other"]
        return order.compactMap { title in
            guard let list = grouped[title], !list.isEmpty else { return nil }
            return (title, list)
        }
    }

    static func suggestedName(for hz: UInt64) -> String {
        guard let band = BandPlan.band(containing: hz) else {
            return String(format: "%.3f MHz", Double(hz) / 1_000_000)
        }
        // Name after the nearest well-known segment when it's close.
        let nearest = band.segments.min {
            $0.hz.distance(to: hz).magnitude < $1.hz.distance(to: hz).magnitude
        }
        if let nearest, nearest.hz.distance(to: hz).magnitude < 5_000 {
            return "\(band.title) \(nearest.name)"
        }
        return "\(band.title) \(String(format: "%.3f", Double(hz) / 1_000_000))"
    }

    // MARK: Persistence

    private func persistChannels() { save(channels, Key.channels) }
    private func persistRecents() { save(recents, Key.recents) }
    private func persistStack() { save(stack, Key.stack) }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String,
                                           from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
