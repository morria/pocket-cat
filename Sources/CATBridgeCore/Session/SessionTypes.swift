// Session-facing value types: errors, phases, events, policy, snapshot,
// transport seam, clock seam.

import Foundation

// MARK: - Errors (docs/implementation.md §8)

public enum CATBridgeError: Error, Sendable, Equatable {
    case bluetoothUnavailable(String)
    case bridgeNotFound
    case connectionFailed(String)
    case connectionLost
    case pairingRequired
    case bondInvalidated
    case bridgeRejected(op: UInt8, code: CtrlErrCode)
    case bridgeOverflow(OverflowDirection)
    case usbRadioDisconnected
    case radioNotResponding
    case radioRejected(command: String)
    case malformedResponse(String)
    case timedOut(command: String)
    case unsupportedMode(OperatingMode)
    case unsupportedCapability(RadioCapabilities)
    case unsupportedSetting(RigSetting)
    case statusVersionUnsupported(UInt8)
    case invalidArgument(String)
    case notReady
    case pttInterlock(String)
}

// MARK: - Connection lifecycle (docs/implementation.md §6)

public enum ConnectionPhase: Sendable, Equatable {
    case idle
    case connecting
    case bridgeReady
    case identifyingRadio
    case ready
    case reconnecting(attempt: Int)
    case failed(String)
}

// MARK: - Session events

public enum SessionEvent: Sendable, Equatable {
    case pttWatchdogTripped
    case bridgeOverflow(OverflowDirection, dropped: UInt32)
    case usbRadioAttached(BridgeRadioID)
    case usbRadioDetached
    /// A device is plugged into the bridge but no CAT interface could be
    /// opened for it. Distinct from `.usbRadioDetached` so an app can say
    /// "unsupported device" instead of the misleading "no radio".
    case usbDeviceUnsupported(BridgeRadioID)
}

// MARK: - Bridge health (from STATUS)

public struct BridgeHealth: Sendable, Equatable {
    public var baud: UInt32 = 0
    public var droppedUSBToBLE: UInt32 = 0
    public var droppedBLEToUSB: UInt32 = 0
    public var firmwareVersion: String = ""
    public var minimumFreeHeap: UInt32 = 0

    public init() {}

    public init(status: BridgeStatus) {
        baud = status.baud
        droppedUSBToBLE = status.droppedUSBToBLE
        droppedBLEToUSB = status.droppedBLEToUSB
        firmwareVersion = "\(status.firmwareMajor).\(status.firmwareMinor)"
        minimumFreeHeap = status.minimumFreeHeap
    }
}

// MARK: - Immutable state snapshot (crosses actor boundaries; §4)

public struct TransceiverSnapshot: Sendable, Equatable {
    public var connection: ConnectionPhase = .idle
    public var radio: RadioModel?
    public var frequency: Frequency?
    public var mode: OperatingMode?
    public var isTransmitting: Bool = false
    public var sMeter: Int?
    /// RF output power, watts (fractional on radios that report tenths,
    /// e.g. QMX). Filled once at connect and after each `setPower`; radios
    /// with no power readback leave it nil.
    public var power: Double?
    public var bridge: BridgeHealth = BridgeHealth()

    public init() {}
}

// MARK: - Timing policy (injectable; §5.5/§5.6)

public struct PollingPolicy: Sendable {
    /// Absolute per-command deadline at ≥ 9600 baud.
    public var commandDeadline: Duration = .milliseconds(500)
    /// Absolute per-command deadline at 4800 baud.
    public var slowCommandDeadline: Duration = .seconds(1)
    /// Deadline for one `ID;` attempt during the baud probe.
    public var probeDeadline: Duration = .milliseconds(600)
    /// Delay before the single `?;`-busy retry.
    public var busyRetryDelay: Duration = .milliseconds(50)
    /// Idle polling interval (`IF;` cadence).
    public var pollInterval: Duration = .milliseconds(500)
    /// Opt-in: enable the radio's unsolicited state pushes (Yaesu
    /// Auto-Information, `AI1;`) on radios that support them. Pushes fold
    /// into the same state/snapshots the poller feeds, so apps see
    /// near-instant frequency/mode updates with no code change. Polling
    /// continues as a backstop (AI has known interleaving quirks and does
    /// not exist on all radios). Off by default.
    public var enableAutoInformation: Bool = false
    /// PTT watchdog: PTT-off if the app forgets (§7.4). Clears WSPR (2 min).
    public var pttWatchdog: Duration = .seconds(180)
    /// Reconnect backoff bounds.
    public var reconnectMinDelay: Duration = .milliseconds(500)
    public var reconnectMaxDelay: Duration = .seconds(8)
    /// Deadline for a CTRL command's ACK/NAK/answer.
    public var ctrlDeadline: Duration = .seconds(1)

    public init() {}
    public static let `default` = PollingPolicy()
}

// MARK: - Transport seam (§5.1)

public enum TransportEvent: Sendable {
    case connected
    case disconnected(reason: String?)
    case catData(Data)
    case ctrlFrame(Data)
    case statusData(Data)
    case mtuChanged(Int)
}

public protocol BridgeTransport: Sendable {
    /// Single-consumer stream of link events; the session is the consumer.
    var events: AsyncStream<TransportEvent> { get }
    func connect() async throws
    func disconnect() async
    /// Raw CAT bytes toward the radio (transport chunks to the MTU).
    func writeCAT(_ data: Data) async throws
    /// One encoded CTRL frame (reliable write).
    func writeCtrl(_ frame: Data) async throws
    /// Read the STATUS characteristic.
    func readStatus() async throws -> Data
}

// MARK: - Clock seam (deterministic tests; §9.2)

public protocol BridgeClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: BridgeClock {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
