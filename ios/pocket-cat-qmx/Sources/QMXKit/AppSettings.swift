// App-level preferences (not radio settings — those live in the QMX's own
// menu tree). Persisted in UserDefaults, observable so SwiftUI binds
// straight to them.

import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private enum Key {
        static let keepScreenAwake = "qmx.keepScreenAwake"
        static let syncClockOnConnect = "qmx.syncClockOnConnect"
        static let callsign = "qmx.wspr.callsign"
        static let grid = "qmx.wspr.grid"
        static let power = "qmx.wspr.powerDBm"
        static let band = "qmx.wspr.band"
        static let slotInterval = "qmx.wspr.slotInterval"
    }

    private let defaults: UserDefaults

    /// Holds the display on while the app is in the foreground. Off by
    /// default: it costs battery, and the phone is often the only clock in
    /// a portable kit.
    public var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    /// Push the phone's UTC time to the radio on every connect.
    public var syncClockOnConnect: Bool {
        didSet {
            defaults.set(syncClockOnConnect, forKey: Key.syncClockOnConnect)
        }
    }

    // MARK: - WSPR beacon

    public var wsprCallsign: String {
        didSet { defaults.set(wsprCallsign, forKey: Key.callsign) }
    }

    /// Four-character Maidenhead square, e.g. `IO91`.
    public var wsprGrid: String {
        didSet { defaults.set(wsprGrid, forKey: Key.grid) }
    }

    public var wsprPowerDBm: Int {
        didSet { defaults.set(wsprPowerDBm, forKey: Key.power) }
    }

    public var wsprBandName: String {
        didSet { defaults.set(wsprBandName, forKey: Key.band) }
    }

    /// Transmit one frame every N two-minute slots.
    public var wsprSlotInterval: Int {
        didSet { defaults.set(wsprSlotInterval, forKey: Key.slotInterval) }
    }

    public var wsprBand: WSPRBand {
        WSPRBand.all.first { $0.name == wsprBandName }
            ?? WSPRBand.all.first { $0.name == "20 m" }!
    }

    /// The beacon is only sendable if the callsign and grid parse.
    public var wsprIsConfigured: Bool {
        (try? WSPREncoder.symbols(callsign: wsprCallsign, grid: wsprGrid,
                                  powerDBm: wsprPowerDBm)) != nil
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepScreenAwake = defaults.bool(forKey: Key.keepScreenAwake)
        syncClockOnConnect = defaults.object(
            forKey: Key.syncClockOnConnect) as? Bool ?? true
        wsprCallsign = defaults.string(forKey: Key.callsign) ?? ""
        wsprGrid = defaults.string(forKey: Key.grid) ?? ""
        wsprPowerDBm = defaults.object(forKey: Key.power) as? Int ?? 23
        wsprBandName = defaults.string(forKey: Key.band) ?? "20 m"
        wsprSlotInterval = defaults.object(
            forKey: Key.slotInterval) as? Int ?? 3
    }
}
