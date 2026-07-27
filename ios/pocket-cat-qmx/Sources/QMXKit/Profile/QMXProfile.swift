// A saved QMX configuration: the complete menu tree (as discovered live
// over MM) plus operating state. JSON on disk (.qmxjson), pretty-printed
// and sort-keyed so files diff cleanly in version control.

import CATBridgeKit
import Foundation

public struct QMXProfile: Codable, Sendable, Identifiable, Equatable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "qmxjson"

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var notes: String
    public var savedAt: Date
    /// Radio firmware at capture time (`VN` reply), for provenance.
    public var firmwareVersion: String?

    public struct OperatingState: Codable, Sendable, Equatable {
        public var vfoAHz: UInt64?
        public var vfoBHz: UInt64?
        /// QMX MD wire code ("3"/"6"/"7"/"9").
        public var modeCode: String?
        public var sideband: String?    // "USB"/"LSB" (Q1)
        public var split: Bool?
        public var keyerSpeed: Int?

        public init() {}
    }

    public var operating: OperatingState
    /// Menu leaf values keyed by wire path (plus `[column]` for grid
    /// cells) — exactly what `QMXMenuClient.Leaf.key` produces. Values are
    /// the radio's raw strings, so this survives app-side display changes.
    public var menu: [String: String]

    public init(name: String, notes: String = "") {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.savedAt = Date()
        self.operating = OperatingState()
        self.menu = [:]
    }

    // MARK: - Codec

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> QMXProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(QMXProfile.self, from: data)
        guard profile.schemaVersion <= currentSchemaVersion else {
            throw CATBridgeError.invalidArgument(
                "profile schema v\(profile.schemaVersion) is newer than "
                + "this app understands")
        }
        return profile
    }
}

/// One menu difference between a profile and the live radio.
public struct QMXMenuDiff: Sendable, Identifiable, Equatable {
    public var key: String          // wire path (+ column)
    public var displayName: String
    public var currentValue: String?
    public var newValue: String

    public var id: String { key }
}

/// Outcome of applying one entry.
public struct QMXApplyResult: Sendable, Identifiable, Equatable {
    public var key: String
    public var displayName: String
    public var succeeded: Bool
    public var detail: String?

    public var id: String { key }
}

public struct QMXProfileProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int?
    public var currentItem: String

    public init(completed: Int, total: Int?, currentItem: String) {
        self.completed = completed
        self.total = total
        self.currentItem = currentItem
    }
}
