// CoreBluetooth implementation of BridgeTransport. Deliberately thin: the
// session owns all logic; this file only moves bytes and delegate callbacks.
//
// Concurrency: every CBCentralManager/CBPeripheral interaction happens on
// `queue` (the manager's delegate queue); the class is @unchecked Sendable
// under that confinement.

#if canImport(CoreBluetooth)
import CATBridgeCore
import CoreBluetooth
import Foundation
import os

public final class BLEBridgeTransport: NSObject, BridgeTransport,
    @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    private let central: CATBridgeCentral
    private let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "radio.catbridge", category: "ble")

    // Queue-confined state.
    private var catRX: CBCharacteristic?
    private var catTX: CBCharacteristic?
    private var ctrl: CBCharacteristic?
    private var status: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingNotifySubscriptions = 0
    private var writeReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var ctrlWriteContinuation: CheckedContinuation<Void, Error>?
    private var statusReadContinuation: CheckedContinuation<Data, Error>?

    init(central: CATBridgeCentral, peripheral: CBPeripheral,
         queue: DispatchQueue) {
        self.central = central
        self.peripheral = peripheral
        self.queue = queue
        (events, eventContinuation) = AsyncStream.makeStream(
            of: TransportEvent.self)
        super.init()
    }

    // MARK: - BridgeTransport

    public func connect() async throws {
        try await central.establishConnection(to: peripheral)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectContinuation = continuation
                self.peripheral.delegate = self
                self.peripheral.discoverServices([BridgeGATT.service])
            }
        }
        eventContinuation.yield(.connected)
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        eventContinuation.yield(.mtuChanged(mtu))
    }

    public func disconnect() async {
        await central.cancelConnection(to: peripheral)
    }

    public func writeCAT(_ data: Data) async throws {
        let maxLength = peripheral.maximumWriteValueLength(
            for: .withoutResponse)
        var offset = 0
        while offset < data.count {
            let end = min(offset + max(1, maxLength), data.count)
            let chunk = data.subdata(
                in: data.index(data.startIndex, offsetBy: offset)
                    ..< data.index(data.startIndex, offsetBy: end))
            try await writeCATChunk(chunk)
            offset = end
        }
    }

    private func writeCATChunk(_ chunk: Data) async throws {
        // Respect canSendWriteWithoutResponse — the firmware relies on the
        // central honoring WNR backpressure (esp32s3 plan §6).
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.peripheral.canSendWriteWithoutResponse {
                    continuation.resume()
                } else {
                    self.writeReadyWaiters.append(continuation)
                }
            }
        }
        try queueSync {
            guard let catRX = self.catRX else {
                throw CATBridgeError.connectionLost
            }
            self.peripheral.writeValue(chunk, for: catRX,
                                       type: .withoutResponse)
        }
    }

    public func writeCtrl(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let ctrl = self.ctrl else {
                    continuation.resume(
                        throwing: CATBridgeError.connectionLost)
                    return
                }
                self.ctrlWriteContinuation = continuation
                self.peripheral.writeValue(frame, for: ctrl,
                                           type: .withResponse)
            }
        }
    }

    public func readStatus() async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                guard let status = self.status else {
                    continuation.resume(
                        throwing: CATBridgeError.connectionLost)
                    return
                }
                self.statusReadContinuation = continuation
                self.peripheral.readValue(for: status)
            }
        }
    }

    // MARK: - Wiring from the central

    func handleDisconnect(error: (any Error)?) {
        // Runs on `queue` (forwarded by CATBridgeCentral).
        let reason = error.map { mapATTError($0) }
        connectContinuation?.resume(
            throwing: reason ?? CATBridgeError.connectionLost)
        connectContinuation = nil
        ctrlWriteContinuation?.resume(
            throwing: CATBridgeError.connectionLost)
        ctrlWriteContinuation = nil
        statusReadContinuation?.resume(
            throwing: CATBridgeError.connectionLost)
        statusReadContinuation = nil
        for waiter in writeReadyWaiters { waiter.resume() }
        writeReadyWaiters.removeAll()
        catRX = nil
        catTX = nil
        ctrl = nil
        status = nil
        eventContinuation.yield(
            .disconnected(reason: error?.localizedDescription))
    }

    // MARK: - Helpers

    private func queueSync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    private func mapATTError(_ error: any Error) -> CATBridgeError {
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain {
            switch nsError.code {
            case CBATTError.insufficientAuthentication.rawValue,
                 CBATTError.insufficientEncryption.rawValue:
                return .pairingRequired
            default:
                break
            }
        }
        return .connectionFailed(error.localizedDescription)
    }
}

extension BLEBridgeTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: (any Error)?) {
        if let error {
            connectContinuation?.resume(throwing: mapATTError(error))
            connectContinuation = nil
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == BridgeGATT.service
        }) else {
            connectContinuation?.resume(
                throwing: CATBridgeError.connectionFailed(
                    "bridge service not found"))
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics(BridgeGATT.characteristics,
                                           for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: (any Error)?) {
        if let error {
            connectContinuation?.resume(throwing: mapATTError(error))
            connectContinuation = nil
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BridgeGATT.catRX: catRX = characteristic
            case BridgeGATT.catTX: catTX = characteristic
            case BridgeGATT.ctrl: ctrl = characteristic
            case BridgeGATT.status: status = characteristic
            default: break
            }
        }
        guard let catTX, let ctrl, let status, catRX != nil else {
            connectContinuation?.resume(
                throwing: CATBridgeError.connectionFailed(
                    "bridge characteristics missing"))
            connectContinuation = nil
            return
        }
        pendingNotifySubscriptions = 3
        peripheral.setNotifyValue(true, for: catTX)
        peripheral.setNotifyValue(true, for: ctrl)
        peripheral.setNotifyValue(true, for: status)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor
                           characteristic: CBCharacteristic,
                           error: (any Error)?) {
        if let error {
            // Encrypted characteristics surface pairing here on iOS.
            connectContinuation?.resume(throwing: mapATTError(error))
            connectContinuation = nil
            return
        }
        pendingNotifySubscriptions -= 1
        if pendingNotifySubscriptions == 0 {
            connectContinuation?.resume()
            connectContinuation = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        if characteristic.uuid == BridgeGATT.status {
            if let continuation = statusReadContinuation {
                statusReadContinuation = nil
                if let error {
                    continuation.resume(throwing: mapATTError(error))
                } else {
                    continuation.resume(
                        returning: characteristic.value ?? Data())
                }
            }
            if let value = characteristic.value, error == nil {
                eventContinuation.yield(.statusData(value))
            }
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case BridgeGATT.catTX:
            eventContinuation.yield(.catData(value))
        case BridgeGATT.ctrl:
            eventContinuation.yield(.ctrlFrame(value))
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        guard characteristic.uuid == BridgeGATT.ctrl,
              let continuation = ctrlWriteContinuation else { return }
        ctrlWriteContinuation = nil
        if let error {
            continuation.resume(throwing: mapATTError(error))
        } else {
            continuation.resume()
        }
    }

    public func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral) {
        for waiter in writeReadyWaiters { waiter.resume() }
        writeReadyWaiters.removeAll()
    }
}
#endif
