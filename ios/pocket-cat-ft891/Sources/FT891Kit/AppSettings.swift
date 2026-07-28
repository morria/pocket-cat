// App-level preferences (not radio settings — those are the FT-891's own
// menu items). Persisted in UserDefaults, observable so SwiftUI binds
// straight to them.

import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private enum Key {
        static let keepScreenAwake = "ft891.keepScreenAwake"
    }

    private let defaults: UserDefaults

    /// Holds the display on while the app is in the foreground. Off by
    /// default: it costs battery, and the phone is often the only clock in
    /// a portable kit.
    public var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepScreenAwake = defaults.bool(forKey: Key.keepScreenAwake)
    }
}
