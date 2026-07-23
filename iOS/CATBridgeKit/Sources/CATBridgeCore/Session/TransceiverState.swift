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

    func apply(_ snapshot: TransceiverSnapshot) {
        connection = snapshot.connection
        radio = snapshot.radio
        frequency = snapshot.frequency
        mode = snapshot.mode
        isTransmitting = snapshot.isTransmitting
        sMeter = snapshot.sMeter
        bridge = snapshot.bridge
    }
}
