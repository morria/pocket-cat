// App-level preferences (not radio settings — those are the FTX-1's own
// menu items). Persisted in UserDefaults, observable so SwiftUI binds
// straight to them.

import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private enum Key {
        static let keepScreenAwake = "ftx1.keepScreenAwake"
        static let callsign = "ftx1.station.callsign"
        static let grid = "ftx1.station.grid"
        static let operatorName = "ftx1.station.name"
        static let qth = "ftx1.station.qth"
    }

    private let defaults: UserDefaults

    /// Holds the display on while the app is in the foreground. Off by
    /// default: it costs battery, and the phone is often the only clock in
    /// a portable kit.
    public var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    // MARK: - Station identity, used by the CW templates

    public var callsign: String {
        didSet { defaults.set(callsign, forKey: Key.callsign) }
    }

    public var grid: String {
        didSet { defaults.set(grid, forKey: Key.grid) }
    }

    public var operatorName: String {
        didSet { defaults.set(operatorName, forKey: Key.operatorName) }
    }

    public var qth: String {
        didSet { defaults.set(qth, forKey: Key.qth) }
    }

    public var station: StationIdentity {
        StationIdentity(callsign: callsign, name: operatorName, qth: qth,
                        grid: grid)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepScreenAwake = defaults.bool(forKey: Key.keepScreenAwake)
        callsign = defaults.string(forKey: Key.callsign) ?? ""
        grid = defaults.string(forKey: Key.grid) ?? ""
        operatorName = defaults.string(forKey: Key.operatorName) ?? ""
        qth = defaults.string(forKey: Key.qth) ?? ""
    }
}
