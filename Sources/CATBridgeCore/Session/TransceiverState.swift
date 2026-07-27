// UI-facing observable state (docs/implementation.md §4). MainActor-isolated
// and updated by the session via snapshots; SwiftUI binds directly.

import Observation

@MainActor
@Observable
public final class TransceiverState {
    public private(set) var connection: ConnectionPhase = .idle
    public private(set) var radio: RadioModel?
    public private(set) var frequency: Frequency?
    public private(set) var mode: OperatingMode?
    public private(set) var isTransmitting: Bool = false
    public private(set) var sMeter: Int?
    public private(set) var bridge: BridgeHealth = BridgeHealth()

    public nonisolated init() {}

    /// Highest sequence applied so far. Hops to the main actor are not
    /// ordered relative to each other, so a late-arriving older snapshot
    /// must not overwrite newer state (e.g. showing a stale frequency).
    private var lastAppliedSequence: UInt64 = 0

    func apply(_ snapshot: TransceiverSnapshot, sequence: UInt64) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence
        connection = snapshot.connection
        radio = snapshot.radio
        frequency = snapshot.frequency
        mode = snapshot.mode
        isTransmitting = snapshot.isTransmitting
        sMeter = snapshot.sMeter
        bridge = snapshot.bridge
    }
}
