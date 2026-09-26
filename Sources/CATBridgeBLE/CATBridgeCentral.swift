// The process's single CBCentralManager owner (docs/implementation.md §4):
// CoreBluetooth peripherals are only usable by the central that discovered
// them, so scanning and connecting share this object by construction.

#if canImport(CoreBluetooth)
import CATBridgeCore
import CoreBluetooth
import Foundation
import os

public final class CATBridgeCentral: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "radio.catbridge.central")
    private var manager: CBCentralManager!
    private let log = Logger(subsystem: "radio.catbridge",
                             category: "central")

    // Queue-confined state.
    private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var scanContinuations:
        [UUID: AsyncStream<DiscoveredBridge>.Continuation] = [:]
    private var connectWaiters:
        [UUID: CheckedContinuation<Void, Error>] = [:]
    private var transports: [UUID: BLEBridgeTransport] = [:]

    /// - Parameter restorationIdentifier: pass a stable ID to opt into
    ///   CoreBluetooth state restoration (iOS only; requires the app's
    ///   `bluetooth-central` background mode).
    public init(restorationIdentifier: String? = nil) {
        super.init()
        var options: [String: Any] = [:]
        #if os(iOS)
        if let restorationIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] =
                restorationIdentifier
        }
        #endif
        manager = CBCentralManager(delegate: self, queue: queue,
                                   options: options)
    }

    // MARK: - Discovery

    /// Scan for bridges (by service UUID — matches the firmware's ADV
    /// payload). Each call returns a fresh single-consumer stream; scanning
    /// runs while at least one stream is active.
    public func bridges() -> AsyncStream<DiscoveredBridge> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                self.queue.async {
                    self.scanContinuations[id] = nil
                    if self.scanContinuations.isEmpty {
                        self.manager.stopScan()
                    }
                }
            }
            self.queue.async {
                self.scanContinuations[id] = continuation
                self.emitAlreadyConnected()
                self.startScanIfPoweredOn()
            }
        }
    }

    // MARK: - Sessions

    /// Connect to a discovered bridge and drive the session to ready.
    public func connect(to bridge: DiscoveredBridge,
                        policy: PollingPolicy = .default)
        async throws -> TransceiverSession {
        try await connect(id: bridge.id, policy: policy)
    }

    /// Connect by persisted identifier (auto-reconnect on later launches).
    public func connect(id: UUID, policy: PollingPolicy = .default)
        async throws -> TransceiverSession {
        try await waitUntilPoweredOn()
        let peripheral = try queueSyncPeripheral(id: id)
        if queueSyncHeldByAnotherApp(peripheral) {
            throw CATBridgeError.bridgeInUse
        }
        let transport = BLEBridgeTransport(central: self,
                                           peripheral: peripheral,
                                           queue: queue)
        queue.async { self.transports[id] = transport }
        let session = TransceiverSession(transport: transport,
                                         policy: policy)
        do {
            try await session.start()
        } catch {
            // A failed handshake must not leave the BLE link up behind a
            // discarded session: the bridge then stops advertising, the
            // app lists it as "Connected" while showing no session, and
            // the next attempt shares the peripheral with this zombie —
            // its late CTRL replies land in the new session's handshake.
            await session.disconnect()
            queue.async {
                if self.transports[id] === transport {
                    self.transports[id] = nil
                }
            }
            throw error
        }
        return session
    }

    /// iOS shares one physical link between every app that connects to a
    /// peripheral, but `CBPeripheral.state` is per process: a peripheral
    /// the system lists as connected while ours says `.disconnected` is
    /// held by another app. (After state restoration our own link shows
    /// as `.connected`, so a relaunch is not mistaken for a sibling.)
    private func heldByAnotherApp(_ peripheral: CBPeripheral) -> Bool {
        guard peripheral.state != .connected else { return false }
        return manager.retrieveConnectedPeripherals(
            withServices: [BridgeGATT.service])
            .contains { $0.identifier == peripheral.identifier }
    }

    private func queueSyncHeldByAnotherApp(_ peripheral: CBPeripheral)
        -> Bool {
        var held = false
        queue.sync { held = heldByAnotherApp(peripheral) }
        return held
    }

    private func queueSyncPeripheral(id: UUID) throws -> CBPeripheral {
        var found: CBPeripheral?
        queue.sync {
            found = manager.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let found else { throw CATBridgeError.bridgeNotFound }
        return found
    }

    // MARK: - Connection plumbing (used by BLEBridgeTransport)

    /// CoreBluetooth's `connect` never times out on its own: a bridge that
    /// is connected to some other device (the iPad, say) stops advertising
    /// and the attempt would wait forever with no error to show.
    static let connectTimeout: DispatchTimeInterval = .seconds(15)

    func establishConnection(to peripheral: CBPeripheral) async throws {
        try await waitUntilPoweredOn()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if peripheral.state == .connected {
                    continuation.resume()
                    return
                }
                let id = peripheral.identifier
                self.connectWaiters[id] = continuation
                self.manager.connect(peripheral)
                self.queue.asyncAfter(deadline: .now() + Self.connectTimeout) {
                    guard let waiter = self.connectWaiters.removeValue(
                        forKey: id) else { return }
                    self.manager.cancelPeripheralConnection(peripheral)
                    waiter.resume(throwing: CATBridgeError.connectionFailed(
                        "bridge not reachable — is it powered, in range, "
                        + "and not connected to another device?"))
                }
            }
        }
    }

    func cancelConnection(to peripheral: CBPeripheral) async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.manager.cancelPeripheralConnection(peripheral)
                continuation.resume()
            }
        }
    }

    private func waitUntilPoweredOn() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.manager.state {
                case .poweredOn:
                    continuation.resume()
                case .unauthorized:
                    continuation.resume(
                        throwing: CATBridgeError.bluetoothUnavailable(
                            "unauthorized"))
                case .unsupported:
                    continuation.resume(
                        throwing: CATBridgeError.bluetoothUnavailable(
                            "unsupported"))
                default:
                    self.poweredOnWaiters.append(continuation)
                }
            }
        }
    }

    /// Surface bridges iOS already has connected.
    ///
    /// Without this, discovery could never find a bonded bridge: the
    /// firmware stops advertising while connected, so `scanForPeripherals`
    /// reports nothing and the app scans forever. That is why "forget this
    /// device" appeared to be the only way to reconnect — it tore down the
    /// system's link, and the bridge started advertising again.
    private func emitAlreadyConnected() {
        guard manager.state == .poweredOn else { return }
        for peripheral in manager.retrieveConnectedPeripherals(
            withServices: [BridgeGATT.service]) {
            let bridge = DiscoveredBridge(
                id: peripheral.identifier,
                name: peripheral.name,
                rssi: nil,
                isAlreadyConnected: true,
                isHeldByAnotherApp: peripheral.state != .connected)
            for continuation in scanContinuations.values {
                continuation.yield(bridge)
            }
        }
    }

    private func startScanIfPoweredOn() {
        guard manager.state == .poweredOn,
              !scanContinuations.isEmpty else { return }
        manager.scanForPeripherals(
            withServices: [BridgeGATT.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
}

extension CATBridgeCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            for waiter in poweredOnWaiters { waiter.resume() }
            poweredOnWaiters.removeAll()
            // Retrieval needs the radio powered on, so a scan that started
            // before Bluetooth was ready must re-check now.
            emitAlreadyConnected()
            startScanIfPoweredOn()
        case .poweredOff, .unauthorized, .unsupported:
            let reason = "\(central.state)"
            for waiter in poweredOnWaiters {
                waiter.resume(throwing:
                    CATBridgeError.bluetoothUnavailable(reason))
            }
            poweredOnWaiters.removeAll()
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let bridge = DiscoveredBridge(
            id: peripheral.identifier,
            name: (advertisementData[CBAdvertisementDataLocalNameKey]
                   as? String) ?? peripheral.name,
            rssi: RSSI.intValue,
            isAlreadyConnected: false)
        for continuation in scanContinuations.values {
            continuation.yield(bridge)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        connectWaiters.removeValue(
            forKey: peripheral.identifier)?.resume()
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: (any Error)?) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?
            .resume(throwing: CATBridgeError.connectionFailed(
                error?.localizedDescription ?? "unknown"))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: (any Error)?) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?
            .resume(throwing: CATBridgeError.connectionLost)
        transports[peripheral.identifier]?.handleDisconnect(error: error)
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        // Peripherals restored here become retrievable by identifier; the
        // app reconnects via connect(id:) after relaunch.
        log.info("state restoration: \(dict.keys.joined(separator: ","))")
    }
    #endif
}
#endif
