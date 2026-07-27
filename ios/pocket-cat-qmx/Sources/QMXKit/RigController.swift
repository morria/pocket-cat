// The app-facing store: owns the session, drives connection, and layers
// QMX state (sideband, RIT, split, keyer speed, TX meters) on top of
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

    public private(set) var sideband: Sideband = .usb
    public private(set) var splitEnabled = false
    public private(set) var ritEnabled = false
    public private(set) var ritOffset = 0
    public private(set) var vfoB: Frequency?
    public private(set) var keyerSpeed: Int?
    public private(set) var firmwareVersion: String?
    /// TX-time meters, polled only while transmitting.
    public private(set) var swr: Double?
    public private(set) var agcDB: Int?
    /// One-line, user-facing notices (watchdog trips, errors). Newest last.
    public private(set) var notices: [String] = []

    public private(set) var discovered: [DiscoveredBridge] = []
    public private(set) var isScanning = false
    public private(set) var isSimulated = false

    public var connectionPhase: ConnectionPhase {
        state?.connection ?? .idle
    }

    public var currentMode: QMXMode? {
        state?.mode.flatMap(QMXMode.init(operatingMode:))
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

    private static let lastBridgeKey = "qmx.lastBridgeID"

    public init() {}

    /// Connect to the in-process simulator (previews, demo mode, tests).
    public func connectSimulator() async {
        let session = TransceiverSession(transport: QMXSimTransport())
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
                if let index = self.discovered.firstIndex(
                    where: { $0.id == bridge.id }) {
                    self.discovered[index] = bridge
                } else {
                    self.discovered.append(bridge)
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
        // One automatic retry: first contact after (re)pairing or a bridge
        // reboot can time out while the bridge settles.
        for attempt in 1...2 {
            do {
                let session = try await central.connect(
                    id: id, policy: .default)
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
        let fresh = CATBridgeCentral(restorationIdentifier: "qmx.central")
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
            Task {
                await refreshSecondaryState()
                await reassertPanadapterAfterAttach()
            }
        case let .usbDeviceUnsupported(id):
            notify("Unsupported USB device (\(String(describing: id))).")
        case let .bridgeOverflow(direction, dropped):
            notify("Bridge dropped \(dropped) bytes "
                   + "(\(String(describing: direction))).")
        }
    }

    public func refreshSecondaryState() async {
        guard let session else { return }
        sideband = (try? await session.readSideband()) ?? sideband
        splitEnabled = (try? await session.readSplit()) ?? splitEnabled
        ritEnabled = (try? await session.readRITEnabled()) ?? ritEnabled
        ritOffset = (try? await session.readRITOffset()) ?? ritOffset
        vfoB = try? await session.readVFOB()
        keyerSpeed = try? await session.read(.keyerSpeed)
        firmwareVersion = try? await session.readFirmwareVersion()
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
        // QMX-series coverage: LF through 6 m, band-table permitting.
        guard next >= 130_000, next <= 54_000_000 else { return }
        tune(to: Frequency(hz: UInt64(next)))
    }

    public func setMode(_ mode: QMXMode) async {
        guard let session else { return }
        do { try await session.setMode(mode.operatingMode) }
        catch { notify(friendlyMessage(for: error)) }
    }

    public func setSideband(_ new: Sideband) async {
        guard let session else { return }
        do {
            try await session.setSideband(new)
            sideband = new
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func setSplit(_ on: Bool) async {
        guard let session else { return }
        do {
            try await session.setSplit(on)
            splitEnabled = try await session.readSplit()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func setRIT(enabled: Bool) async {
        guard let session else { return }
        do {
            try await session.setRIT(enabled: enabled)
            ritEnabled = enabled
            if !enabled {
                try await session.clearRIT()
                ritOffset = 0
            }
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func nudgeRIT(by hz: Int) async {
        guard let session else { return }
        do {
            // Absolute vs relative follows the radio's "CAT RU and RD"
            // setting; send the new absolute target and re-read the truth.
            try await session.sendRITOffset(ritOffset + hz)
            ritOffset = try await session.readRITOffset()
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func clearRIT() async {
        guard let session else { return }
        try? await session.clearRIT()
        ritOffset = (try? await session.readRITOffset()) ?? 0
    }

    public func setKeyerSpeed(_ wpm: Int) async {
        guard let session else { return }
        do {
            try await session.set(.keyerSpeed, to: wpm)
            keyerSpeed = try await session.read(.keyerSpeed)
        } catch { notify(friendlyMessage(for: error)) }
    }

    public func sendKeyerText(_ text: String) async {
        guard let session else { return }
        do { try await session.send(keyerText: text) }
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
        swr = nil
        do { try await session.receive() }
        catch { notify(friendlyMessage(for: error)) }
    }

    // MARK: - Panadapter (docs/qmx-panadapter.md §5.3, §6)

    /// nil until probed; false on pre-panadapter firmware.
    public private(set) var spectrumSupported: Bool?
    public private(set) var panadapterActive = false
    public private(set) var latestSpectrum: SpectrumFrame?
    public private(set) var spectrumFramesLost = 0
    private var spectrumTask: Task<Void, Never>?

    public func probePanadapter() async {
        guard let session else { return }
        spectrumSupported = (try? await session.probeSpectrumSupport())
            ?? false
    }

    /// Turn the panadapter on: switch the radio's sound card to I/Q
    /// (Q9 — replacing its demodulated audio), verify it took, then start
    /// the bridge's spectrum stream and consume frames.
    public func startPanadapter(bins: UInt16 = 256,
                                fps: UInt8 = 15) async {
        guard let session, !panadapterActive else { return }
        do {
            try await session.setIQMode(true)
            guard try await session.readIQMode() else {
                notify("Radio refused I/Q mode (Q9).")
                return
            }
            try await session.setSpectrum(bins: bins, fps: fps)
        } catch {
            notify(friendlyMessage(for: error))
            return
        }
        panadapterActive = true
        spectrumTask?.cancel()
        spectrumTask = Task { [weak self] in
            guard let session = self?.session else { return }
            for await frame in await session.spectrumFrames() {
                guard let self else { return }
                self.latestSpectrum = frame
                self.spectrumFramesLost = await session.spectrumFramesLost
            }
        }
    }

    /// Stop streaming and hand the sound card back to demodulated audio.
    public func stopPanadapter() async {
        guard panadapterActive else { return }
        panadapterActive = false
        spectrumTask?.cancel()
        spectrumTask = nil
        latestSpectrum = nil
        if let session {
            await session.stopSpectrum()
            try? await session.setIQMode(false)
        }
    }

    /// Q9 is session-only on the radio: a power cycle (USB re-attach)
    /// silently reverts it, so re-assert and restart the stream.
    private func reassertPanadapterAfterAttach() async {
        guard panadapterActive, let session else { return }
        do {
            try await session.setIQMode(true)
            guard try await session.readIQMode() else { return }
            try await session.setSpectrum(bins: 256, fps: 15)
        } catch {
            panadapterActive = false
            notify("Panadapter stopped: \(friendlyMessage(for: error))")
        }
    }

    // MARK: - TX meter polling (SWR + power are only live while keyed)

    private func startMeterPolling() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                self.swr = (try? await session.readSWR()) ?? nil
                _ = try? await session.readPower() // updates snapshot.power
                self.agcDB = try? await session.readAGCMeter()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    // MARK: - Notices

    func notify(_ message: String) {
        notices.append(message)
        if notices.count > 5 { notices.removeFirst() }
    }

    public func dismissNotice(_ message: String) {
        notices.removeAll { $0 == message }
    }

    func friendlyMessage(for error: Error) -> String {
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
            return "The bridge lost its pairing (re-flashed?). Forget it "
                + "in Settings → Bluetooth, then reconnect and re-pair."
        case .usbRadioDisconnected:
            return "The radio's USB cable is disconnected from the bridge."
        case .radioNotResponding:
            return "Radio not answering CAT — check the USB cable to the "
                + "QMX and that the radio is powered."
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
