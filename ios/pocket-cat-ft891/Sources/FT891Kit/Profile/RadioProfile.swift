// A saved radio configuration: every writable menu item plus operating
// state, in engineering units (human-readable JSON that survives wire-
// encoding fixes). Versioned for forward migration.

import Foundation

public struct RadioProfile: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "ft891json"

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var notes: String
    public var savedAt: Date
    /// Firmware versions read from menu 18-01…18-03 at capture, for
    /// provenance ("saved from MAIN v01.07").
    public var radioFirmware: [String: Int]
    public var operating: OperatingState
    /// Menu item id ("05-06") → engineering value.
    public var menu: [String: Int]
    /// Reserved for a future memory-channel manager (fun-features #4).
    public var memories: [String: String]?

    public struct OperatingState: Codable, Sendable, Equatable {
        public var vfoAHz: UInt64?
        public var vfoBHz: UInt64?
        /// Yaesu MD wire code ("2" = USB).
        public var modeCode: String?
        public var powerWatts: Int?
        public var split: Int?

        public init(vfoAHz: UInt64? = nil, vfoBHz: UInt64? = nil,
                    modeCode: String? = nil, powerWatts: Int? = nil,
                    split: Int? = nil) {
            self.vfoAHz = vfoAHz
            self.vfoBHz = vfoBHz
            self.modeCode = modeCode
            self.powerWatts = powerWatts
            self.split = split
        }
    }

    public init(name: String, notes: String = "", savedAt: Date,
                radioFirmware: [String: Int] = [:],
                operating: OperatingState = OperatingState(),
                menu: [String: Int] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.savedAt = savedAt
        self.radioFirmware = radioFirmware
        self.operating = operating
        self.menu = menu
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RadioProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(RadioProfile.self, from: data)
        guard profile.schemaVersion <= currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "Profile schema v\(profile.schemaVersion) is newer than this app understands.",
            ])
        }
        return profile
    }
}

/// One menu-item difference between a profile and the live radio.
public struct MenuDiff: Sendable, Equatable, Identifiable {
    public let item: MenuItem
    public let currentValue: Int?
    public let newValue: Int

    public var id: String { item.id }

    public init(item: MenuItem, currentValue: Int?, newValue: Int) {
        self.item = item
        self.currentValue = currentValue
        self.newValue = newValue
    }
}

/// Per-item outcome of applying a profile.
public struct ApplyResult: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case applied
        case failed(String)
    }

    public let itemID: String
    public let outcome: Outcome

    public var id: String { itemID }

    public init(itemID: String, outcome: Outcome) {
        self.itemID = itemID
        self.outcome = outcome
    }
}
