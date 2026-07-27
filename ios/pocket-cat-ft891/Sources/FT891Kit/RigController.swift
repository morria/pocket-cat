// The app-facing store: owns the session, drives connection, and layers
// FT-891 state (tuner, split, clarifier, TX meters, menu cache) on top of
// CATBridgeKit's TransceiverState. MainActor-isolated; SwiftUI binds
// directly.

import CATBridgeCore
import Foundation
import Observation
#if canImport(CoreBluetooth)
import CATBridgeBLE
#endif

@MainActor
@Observable
public final class RigController {
    // MARK: - Published state

    public private(set) var session: TransceiverSession?
    /// Mirror of the library's observable state (nil before connect).
    public private(set) var state: TransceiverState?

    public private(set) var tunerState: TunerState = .off
    public private(set) var splitState: SplitState = .off
    public private(set) var clarifierEnabled = false
    public private(set) var vfoB: Frequency?
    /// Raw 0–255 TX meters, polled only while transmitting or tuning.
    public private(set) var swrMeter: Int?
    public private(set) var alcMeter: Int?
    public private(set) var poMeter: Int?
    /// Menu item id → engineering value, filled lazily by the Settings UI.
    public private(set) var menuValues: [String: Int] = [:]
    public private(set) var menuBusy = false
    /// One-line, user-facing notices (watchdog trips, errors). Newest last.
    public private(set) var notices: [String] = []
    public private(set) var isTuning = false

    public private(set) var discovered: [DiscoveredBridge] = []
    public private(set) var isScanning = false
    public private(set) var isSimulated = false

    public var connectionPhase: ConnectionPhase {
        state?.connection ?? .idle
    }

    // MARK: - Lifecycle

    #if canImport(CoreBluetooth)
    private var central: CATBridgeCentral?
    #endif
    private var scanTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var pendingFrequency: Frequency?
    private var frequencySendInFlight = false

    private static let lastBridgeKey = "ft891.lastBridgeID"

    public init() {}

    /// Connect to the in-process simulator (previews, demo mode, tests).
    public func connectSimulator() async {
        let transport = FT891SimTransport()
        var policy = PollingPolicy.default
        policy.enableAutoInformation = true
        let session = TransceiverSession(transport: transport, policy: policy)
        isSimulated = true
        await adopt(session: session)
    }

    #if canImport(CoreBluetooth)
    public func startScanning() {
        guard scanTask == nil else { return }
        let central = ensureCentral()
        isScanning = true
        scanTask = Task { [weak self] in
            for await bridge in central.bridges() {
                guard let self else { return }
                if !self.discovered.contains(where: { $0.id == bridge.id }) {
                    self.discovered.append(bridge)
                } else if let index = self.discovered.firstIndex(
                    where: { $0.id == bridge.id }) {
                    self.discovered[index] = bridge
                }
            }
        }
    }

    public func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    public func connect(to bridge: DiscoveredBridge) async {
        stopScanning()
        await connectBluetooth(id: bridge.id)
    }

    /// Reconnect to the last bridge, if one was remembered.
    public var lastBridgeID: UUID? {
        UserDefaults.standard.string(forKey: Self.lastBridgeKey)
            .flatMap(UUID.init(uuidString:))
    }

    public func connectLast() async {
        guard let id = lastBridgeID else { return }
        await connectBluetooth(id: id)
    }

    private func connectBluetooth(id: UUID) async {
        let central = ensureCentral()
        var policy = PollingPolicy.default
        policy.enableAutoInformation = true
        // One automatic retry: first contact after (re)pairing or a bridge
        // reboot can time out a CTRL command while the bridge is still
        // settling (e.g. a slow CP210x line-state call); attempt two lands.
        for attempt in 1...2 {
            do {
                let session = try await central.connect(id: id,
                                                        policy: policy)
                UserDefaults.standard.set(id.uuidString,
                                          forKey: Self.lastBridgeKey)
                isSimulated = false
                await adopt(session: session)
                return
            } catch {
                let retryable: Bool = switch error as? CATBridgeError {
                case .timedOut, .connectionLost, .radioNotResponding:
                    true
                default:
                    false
                }
                if attempt == 2 || !retryable {
                    notify(friendlyMessage(for: error))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func ensureCentral() -> CATBridgeCentral {
        if let central { return central }
        let fresh = CATBridgeCentral(
            restorationIdentifier: "ft891.central")
        central = fresh
        return fresh
    }
    #endif

    public func disconnect() async {
        meterTask?.cancel()
        eventTask?.cancel()
        if let session {
            await session.disconnect()
        }
        session = nil
        state = nil
        isSimulated = false
    }

    private func adopt(session: TransceiverSession) async {
        self.session = session
        self.state = session.state
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in await session.events() {
                self?.handle(event)
            }
        }
        do {
            try await session.start()
            await refreshSecondaryState()
        } catch {
            notify(friendlyMessage(for: error))
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .pttWatchdogTripped:
            notify("Transmit watchdog unkeyed the radio.")
        case .usbRadioDetached:
            notify("Radio USB disconnected from the bridge.")
        case let .usbRadioAttached(id):
            notify("Radio attached (\(String(describing: id))).")
            Task { await refreshSecondaryState() }
        case let .usbDeviceUnsupported(id):
            notify("Unsupported USB device (\(String(describing: id))).")
        case let .bridgeOverflow(direction, dropped):
            notify("Bridge dropped \(dropped) bytes "
                   + "(\(String(describing: direction))).")
        }
    }

    // MARK: - Operate actions

    /// Latest-wins frequency setter: while one FA write is in flight,
    /// intermediate values are dropped so scrubbing never builds a backlog.
    public func tune(to frequency: Frequency) {
        pendingFrequency = frequency
        guard !frequencySendInFlight else { return }
        frequencySendInFlight = true
        Task { [weak self] in
            await self?.drainPendingFrequency()
        }
    }

    private func drainPendingFrequency() async {
        defer { frequencySendInFlight = false }
        while let target = pendingFrequency {
            pendingFrequency = nil
            guard let session else { return }
            try? await session.setFrequency(target)
        }
    }

    public func step(by hz: Int64) {
        guard let current = state?.frequency else { return }
        let next = Int64(current.hertz) + hz
        guard next >= 30_000, next <= 56_000_000 else { return }
        tune(to: Frequency(hz: UInt64(next)))
    }

    public func setMode(_ mode: OperatingMode) async {
        guard let session else { return }
        do { try await session.setMode(mode) }
        catch { notify(friendlyMessage(for: error)) }
    }

    public func selectBand(_ band: FT891Band) async {
        guard let session else { return }
        do {
            try await session.selectBand(band)
            _ = try await session.readFrequency()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func setPower(watts: Int) async {
        guard let session else { return }
        do { try await session.setPower(watts: watts) }
        catch { notify(friendlyMessage(for: error)) }
    }

    public func pressPTT() async {
        guard let session else { return }
        do {
            try await session.transmit()
            startMeterPolling()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func releasePTT() async {
        guard let session else { return }
        meterTask?.cancel()
        do { try await session.receive() }
        catch { notify(friendlyMessage(for: error)) }
    }

    /// Start a tune cycle (transmits a carrier). Polls `AC` until the
    /// radio reports done, publishing live SWR meanwhile.
    public func startTuneCycle() async {
        guard let session, !isTuning else { return }
        isTuning = true
        defer { isTuning = false }
        do {
            try await session.startTuneCycle()
            startMeterPolling()
            for _ in 0..<40 { // ~20 s ceiling
                try await Task.sleep(for: .milliseconds(500))
                let tuner = try await session.readTunerState()
                tunerState = tuner
                if tuner != .tuning { break }
            }
        } catch { notify(friendlyMessage(for: error)) }
        meterTask?.cancel()
        swrMeter = nil; alcMeter = nil; poMeter = nil
    }

    public func setTuner(enabled: Bool) async {
        guard let session else { return }
        do {
            try await session.setTuner(enabled: enabled)
            tunerState = try await session.readTunerState()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func setSplit(_ split: SplitState) async {
        guard let session else { return }
        do {
            try await session.setSplit(split)
            splitState = try await session.readSplit()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func setClarifier(enabled: Bool) async {
        guard let session else { return }
        do {
            try await session.setClarifier(enabled: enabled)
            clarifierEnabled = enabled
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func nudgeClarifier(by hz: Int) async {
        guard let session else { return }
        try? await session.nudgeClarifier(by: hz)
    }

    public func clearClarifier() async {
        guard let session else { return }
        try? await session.clearClarifier()
    }

    public func swapVFOs() async {
        guard let session else { return }
        do {
            try await session.swapVFOs()
            _ = try await session.readFrequency()
            vfoB = try await session.readVFOB()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func refreshSecondaryState() async {
        guard let session else { return }
        tunerState = (try? await session.readTunerState()) ?? tunerState
        splitState = (try? await session.readSplit()) ?? splitState
        clarifierEnabled =
            (try? await session.readClarifierEnabled()) ?? clarifierEnabled
        vfoB = try? await session.readVFOB()
    }

    // MARK: - RX settings (typed RigSetting passthrough)

    public func readSetting(_ setting: RigSetting) async -> Int? {
        guard let session else { return nil }
        return try? await session.read(setting)
    }

    public func setSetting(_ setting: RigSetting, to value: Int) async {
        guard let session else { return }
        do { try await session.set(setting, to: value) }
        catch { notify(friendlyMessage(for: error)) }
    }

    // MARK: - Menu access

    public func loadMenuValue(_ item: MenuItem) async {
        guard let session, menuValues[item.id] == nil else { return }
        menuValues[item.id] = try? await session.readMenuValue(item)
    }

    public func loadMenuValues(in group: MenuGroup) async {
        guard let session else { return }
        for item in MenuCatalog.items(in: group)
        where menuValues[item.id] == nil {
            menuValues[item.id] = try? await session.readMenuValue(item)
        }
    }

    public func writeMenuValue(_ item: MenuItem, value: Int) async {
        guard let session else { return }
        menuBusy = true
        defer { menuBusy = false }
        do {
            if try await session.readFrontPanelMenuActive() {
                notify("Radio is in its front-panel menu — "
                       + "exit it on the radio first.")
                return
            }
            try await session.writeMenuValue(item, value: value)
            let readback = try await session.readMenuValue(item)
            menuValues[item.id] = readback
            if readback != value {
                notify("\(item.friendlyName): radio kept "
                       + "\(item.label(for: readback)).")
            }
        } catch {
            notify("\(item.friendlyName): \(friendlyMessage(for: error))")
        }
    }

    // MARK: - TX meter polling

    private func startMeterPolling() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                let swr = try? await session.readMeter(.swr)
                let alc = try? await session.readMeter(.alc)
                let po = try? await session.readMeter(.power)
                self.swrMeter = swr
                self.alcMeter = alc
                self.poMeter = po
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: - Notices

    private func notify(_ message: String) {
        notices.append(message)
        if notices.count > 5 { notices.removeFirst() }
    }

    public func dismissNotice(_ message: String) {
        notices.removeAll { $0 == message }
    }

    private func friendlyMessage(for error: Error) -> String {
        guard let error = error as? CATBridgeError else {
            return String(describing: error)
        }
        switch error {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable — check Settings."
        case .bridgeNotFound:
            return "Bridge not found — is it powered and in range?"
        case .pairingRequired:
            return "Pairing required — accept the pairing request."
        case .bondInvalidated:
            return "Pairing is stale. Forget the bridge in Settings → "
                + "Bluetooth, then reconnect."
        case let .connectionFailed(reason)
            where reason.localizedCaseInsensitiveContains("pairing"):
            // CoreBluetooth reports a wiped bridge bond store (e.g. after
            // re-flashing) as "Peer removed pairing information".
            return "The bridge lost its pairing (re-flashed?). Forget it "
                + "in Settings → Bluetooth, then reconnect and re-pair."
        case .usbRadioDisconnected:
            return "The radio's USB cable is disconnected from the bridge."
        case .radioNotResponding:
            return "Radio not answering CAT. Check the cable and menu "
                + "05-06 CAT RATE (set 38400 for best speed)."
        case let .radioRejected(command):
            return "Radio rejected \(command)."
        case let .timedOut(command):
            return "No reply to \(command)."
        case .pttInterlock:
            return "Transmit blocked: safety interlock not armed yet."
        case .notReady:
            return "Not connected to the radio."
        default:
            return String(describing: error)
        }
    }
}
