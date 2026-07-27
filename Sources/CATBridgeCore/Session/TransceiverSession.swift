// The transceiver session actor (docs/implementation.md §5): command queue,
// polling, baud negotiation, failsafe interlock, reconnect handling. All
// radio I/O serializes through this actor — that is both the concurrency
// model and the CAT correctness model (one in-flight command; the stream has
// no correlation IDs).

import Foundation

public actor TransceiverSession {
    // MARK: - Public surface

    /// UI-facing observable state. Safe to reference from anywhere; property
    /// access is MainActor-gated (where SwiftUI lives).
    public nonisolated let state: TransceiverState

    public init(transport: any BridgeTransport,
                clock: any BridgeClock = SystemClock(),
                policy: PollingPolicy = .default) {
        self.transport = transport
        self.clock = clock
        self.policy = policy
        self.state = TransceiverState()
    }

    /// Connect and drive the link to `ready` (or `bridgeReady` if no radio
    /// is attached to the bridge). Throws on connection or protocol failure.
    public func start() async throws {
        switch model.connection {
        case .idle, .failed:
            break // fresh start, or retry after a failed attempt
        default:
            return
        }
        userDisconnected = false
        eventTask = Task { await self.eventLoop() }
        setPhase(.connecting)
        do {
            try await transport.connect()
            try await initializeLink()
        } catch {
            if case .radioNotResponding = error as? CATBridgeError {
                // Bridge link is up; only the radio is silent. Stay usable.
                setPhase(.bridgeReady)
            } else {
                setPhase(.failed(String(describing: error)))
            }
            throw error
        }
    }

    /// Tear the session down. It does not auto-reconnect after this.
    public func disconnect() async {
        // Politeness: restore AI0; so the radio isn't left pushing frames
        // at other CAT software. Best-effort and deadline-bounded.
        if policy.enableAutoInformation,
           case .ready = model.connection,
           let dialect,
           let disable = dialect.disableAutoInformation {
            _ = try? await execute(disable)
        }
        userDisconnected = true
        pollerTask?.cancel()
        reconnectTask?.cancel()
        watchdogTask?.cancel()
        failCATInFlight(error: .connectionLost)
        failCtrlInFlight(error: .connectionLost)
        // Wake anything queued behind the slot; each will observe the
        // non-ready phase and throw rather than wait forever.
        drainWaiters()
        await transport.disconnect()
        setPhase(.idle)
        eventTask?.cancel()
        // Let consumers' `for await` loops end instead of hanging.
        for continuation in snapshotContinuations.values { continuation.finish() }
        snapshotContinuations.removeAll()
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    private func drainWaiters() {
        let slots = slotWaiters
        slotWaiters.removeAll()
        slotBusy = false
        for waiter in slots { waiter.resume() }
        let ctrls = ctrlWaiters
        ctrlWaiters.removeAll()
        ctrlBusy = false
        for waiter in ctrls { waiter.resume() }
    }

    public var capabilities: RadioCapabilities { dialect?.capabilities ?? [] }

    /// Immutable state snapshots; the current snapshot is emitted first.
    /// Each call returns an independent stream. Streams unregister when the
    /// consumer stops iterating or the task is cancelled.
    public func snapshots() -> AsyncStream<TransceiverSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotConsumer(id) }
            }
            self.snapshotContinuations[id] = continuation
            continuation.yield(self.model)
        }
    }

    /// Out-of-band session events (watchdog, overflow, USB attach/detach).
    public func events() -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventConsumer(id) }
            }
            self.eventContinuations[id] = continuation
        }
    }

    private func removeSnapshotConsumer(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func removeEventConsumer(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    // MARK: - Radio control

    public func setFrequency(_ frequency: Frequency) async throws {
        let dialect = try readyDialect()
        _ = try await execute(try dialect.setFrequency(frequency))
        model.frequency = frequency // optimistic; next poll confirms
        publish()
    }

    public func readFrequency() async throws -> Frequency {
        let dialect = try readyDialect()
        let command = dialect.readFrequency
        guard let reply = try await execute(command),
              case let .frequency(f) = try dialect.parse(reply: reply,
                                                         to: command)
        else { throw CATBridgeError.malformedResponse("FA") }
        model.frequency = f
        publish()
        return f
    }

    public func setMode(_ mode: OperatingMode) async throws {
        let dialect = try readyDialect()
        _ = try await execute(try dialect.setMode(mode))
        model.mode = mode
        publish()
    }

    public func transmit() async throws {
        let dialect = try readyDialect()
        guard dialect.capabilities.contains(.ptt) else {
            throw CATBridgeError.unsupportedCapability(.ptt)
        }
        try await ensureFailsafeArmed()
        _ = try await execute(dialect.pttOn)
        model.isTransmitting = true
        publish()
        startWatchdog()
    }

    public func receive() async throws {
        let dialect = try readyDialect()
        watchdogTask?.cancel()
        _ = try await execute(dialect.pttOff)
        model.isTransmitting = false
        publish()
    }

    public func send(keyerText text: String) async throws {
        let dialect = try readyDialect()
        guard dialect.capabilities.contains(.keyerText) else {
            throw CATBridgeError.unsupportedCapability(.keyerText)
        }
        _ = try await execute(try dialect.keyerText(text))
    }

    /// Raw CAT escape hatch. PTT-on wires are refused while the failsafe is
    /// unarmed; retries are opt-in because raw commands may not be idempotent.
    public func rawCommand(_ wire: String, expectsReply: Bool,
                           isIdempotent: Bool = false) async throws -> String? {
        let dialect = try readyDialect()
        guard wire.hasSuffix(";") else {
            throw CATBridgeError.invalidArgument("CAT commands end with ';'")
        }
        let isPTTOn = wire == dialect.pttOn.wire
        let command = CATCommand(
            wire: wire,
            replyPrefix: expectsReply ? String(wire.prefix(2)) : nil,
            isIdempotent: isIdempotent,
            isPTTOn: isPTTOn)
        let reply = try await execute(command)
        if isPTTOn {
            model.isTransmitting = true
            publish()
            startWatchdog()
        }
        return reply
    }

    /// Diagnostic counters.
    public var garbageFrameCount: Int { demux.garbageFrames }
    /// Live snapshot-stream consumers (diagnostic; guards against leaks).
    public var snapshotConsumerCount: Int { snapshotContinuations.count }

    // MARK: - Private state

    private let transport: any BridgeTransport
    private let clock: any BridgeClock
    private let policy: PollingPolicy

    private var model = TransceiverSnapshot()
    private var lastPublished: TransceiverSnapshot?
    /// Keyed so terminated consumers can unregister — an append-only array
    /// would grow without bound as views come and go.
    private var snapshotContinuations:
        [UUID: AsyncStream<TransceiverSnapshot>.Continuation] = [:]
    private var eventContinuations:
        [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    /// Monotonic publish counter: `Task { @MainActor }` hops are not
    /// ordered, so the observable state drops out-of-order applies.
    private var publishSequence: UInt64 = 0

    private var dialect: (any CATDialect)?
    private var demux = ResponseDemux()
    private var ctrlRxBuffer = Data()
    private var usbEnumerated = false
    private var failsafeArmed = false
    private var currentBaud: UInt32 = 0
    private var userDisconnected = false

    private var eventTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    // Command slot: FIFO turn-taking for the single in-flight CAT command.
    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private struct CATInFlight {
        let id: UUID
        let command: CATCommand
        let continuation: CheckedContinuation<String, Error>
        var deadlineTask: Task<Void, Never>?
        var busyRetried = false
        var timeoutRetried = false
    }
    private var catInFlight: CATInFlight?
    /// Prefix of the last timed-out command; a matching reply arriving
    /// before the next command is sent is a late reply and is discarded.
    private var lastTimedOutPrefix: String?

    private var ctrlBusy = false
    private var ctrlWaiters: [CheckedContinuation<Void, Never>] = []
    private struct CtrlInFlight {
        let id: UUID
        let op: UInt8
        let continuation: CheckedContinuation<CtrlReply, Error>
        var deadlineTask: Task<Void, Never>?
    }
    private var ctrlInFlight: CtrlInFlight?

    // MARK: - Phase / publish

    private func setPhase(_ phase: ConnectionPhase) {
        model.connection = phase
        publish()
    }

    private func publish() {
        guard model != lastPublished else { return }
        lastPublished = model
        let snapshot = model
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
        publishSequence += 1
        let sequence = publishSequence
        let state = self.state
        Task { @MainActor in state.apply(snapshot, sequence: sequence) }
    }

    private func emit(_ event: SessionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func readyDialect() throws -> any CATDialect {
        guard case .ready = model.connection, let dialect else {
            throw CATBridgeError.notReady
        }
        return dialect
    }

    private var commandDeadline: Duration {
        currentBaud != 0 && currentBaud <= 4800
            ? policy.slowCommandDeadline : policy.commandDeadline
    }

    // MARK: - Link initialization (§6)

    private func initializeLink() async throws {
        let statusData = try await transport.readStatus()
        let status = try BridgeStatus(decoding: statusData)
        model.bridge = BridgeHealth(status: status)
        usbEnumerated = status.usbState == .enumerated
        currentBaud = status.baud
        failsafeArmed = false
        setPhase(.bridgeReady)

        guard usbEnumerated else { return } // bridge up, no radio: stay here

        setPhase(.identifyingRadio)
        switch status.radioID {
        case .qmxCDC:
            try await verify(dialect: KenwoodDialect.qmx, exactID: true)
        case .ft891:
            try await probeBaud(dialect: YaesuDialect.ft891, exactID: true)
        case .genericCP210x:
            // FTX-1 candidate: Yaesu dialect, accept any ID reply.
            try await probeBaud(dialect: YaesuDialect.ftx1, exactID: false)
        case .genericFTDI:
            try await probeBaud(dialect: YaesuDialect.ftx1, exactID: false)
        case .none, .unsupported, .unknown:
            setPhase(.bridgeReady)
            return
        }

        try await ensureFailsafeArmed()
        await enableAutoInformationIfRequested()
        startPoller()
        setPhase(.ready)
        await pollOnce() // immediate first state fill
    }

    /// Opt-in Auto-Information (§5.6): best-effort — if the radio rejects
    /// it, the poller still covers every update, just at poll latency.
    /// Runs on every (re)initialization, so reconnects re-enable pushes.
    private func enableAutoInformationIfRequested() async {
        guard policy.enableAutoInformation,
              let dialect,
              dialect.capabilities.contains(.autoInformation),
              let enable = dialect.enableAutoInformation else { return }
        _ = try? await execute(enable, requireReady: false)
    }

    /// Confirm the radio answers `ID;` with this dialect at the current baud.
    private func verify(dialect candidate: any CATDialect,
                        exactID: Bool) async throws {
        let reply = try await execute(candidate.readID,
                                      deadline: policy.probeDeadline,
                                      requireReady: false)
        try adopt(dialect: candidate, idReply: reply, exactID: exactID)
    }

    /// SET_BAUD walk 38400 → 9600 → 4800 with an `ID;` probe at each step
    /// (docs/implementation.md §6).
    private func probeBaud(dialect candidate: any CATDialect,
                           exactID: Bool) async throws {
        for baud in [UInt32(38400), 9600, 4800] {
            let reply = try await performCtrl(CtrlCommand.setBaud(baud))
            guard case .ack = reply else { continue }
            currentBaud = baud
            model.bridge.baud = baud
            do {
                let id = try await execute(candidate.readID,
                                           deadline: policy.probeDeadline,
                                           requireReady: false)
                try adopt(dialect: candidate, idReply: id, exactID: exactID)
                return
            } catch let error as CATBridgeError {
                switch error {
                case .timedOut, .malformedResponse, .radioRejected:
                    continue // wrong baud: silence or garbage — try next
                default:
                    throw error
                }
            }
        }
        throw CATBridgeError.radioNotResponding
    }

    private func adopt(dialect candidate: any CATDialect, idReply: String?,
                       exactID: Bool) throws {
        guard let idReply, idReply.hasPrefix("ID") else {
            throw CATBridgeError.radioNotResponding
        }
        if exactID && idReply != candidate.idReply {
            throw CATBridgeError.malformedResponse(idReply)
        }
        dialect = candidate
        model.radio = exactID
            ? candidate.radioModel
            : (idReply == candidate.idReply ? candidate.radioModel
                                            : .generic(idReply))
        publish()
    }

    private func ensureFailsafeArmed() async throws {
        guard !failsafeArmed, let dialect else { return }
        let frame = try CtrlCommand.setFailsafe(
            Data(dialect.failsafeString.utf8))
        let reply = try await performCtrl(frame)
        guard case .ack = reply else {
            if case let .nak(op, code) = reply {
                throw CATBridgeError.bridgeRejected(op: op, code: code)
            }
            throw CATBridgeError.malformedResponse("SET_FAILSAFE reply")
        }
        failsafeArmed = true
    }

    // MARK: - CAT command execution (§5.5)

    private func acquireSlot() async {
        if !slotBusy {
            slotBusy = true
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    /// Send one CAT command and await its reply (nil for no-reply commands).
    private func execute(_ command: CATCommand,
                         deadline: Duration? = nil,
                         requireReady: Bool = true) async throws -> String? {
        if command.isPTTOn && !failsafeArmed {
            throw CATBridgeError.pttInterlock(
                "failsafe must be armed before PTT")
        }
        await acquireSlot()
        defer { releaseSlot() }
        if Task.isCancelled { throw CancellationError() }
        if requireReady {
            guard case .ready = model.connection else {
                throw CATBridgeError.notReady
            }
        }
        guard usbEnumerated else { throw CATBridgeError.usbRadioDisconnected }
        lastTimedOutPrefix = nil

        let data = Data(command.wire.utf8)
        guard command.replyPrefix != nil else {
            try await transport.writeCAT(data)
            return nil
        }

        let effectiveDeadline = deadline ?? commandDeadline
        let id = UUID()
        // withTaskCancellationHandler is essential: a bare continuation is
        // never resumed when the calling Task is cancelled, which would
        // leak the continuation AND hold the command slot forever — a
        // permanent session deadlock.
        let reply: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                catInFlight = CATInFlight(id: id, command: command,
                                          continuation: continuation)
                catInFlight?.deadlineTask = makeCATDeadline(
                    id: id, after: effectiveDeadline)
                Task {
                    do {
                        try await self.transport.writeCAT(data)
                    } catch {
                        self.failCAT(id: id, error: .connectionLost)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelCAT(id: id) }
        }
        return reply
    }

    /// Abandon a cancelled in-flight command. The reply may still arrive:
    /// record its prefix so the late-reply rule discards it instead of
    /// resolving the *next* command with stale data.
    private func cancelCAT(id: UUID) {
        guard let inFlight = catInFlight, inFlight.id == id else { return }
        inFlight.deadlineTask?.cancel()
        catInFlight = nil
        lastTimedOutPrefix = inFlight.command.replyPrefix
        inFlight.continuation.resume(throwing: CancellationError())
    }

    private func makeCATDeadline(id: UUID, after duration: Duration)
        -> Task<Void, Never> {
        Task {
            try? await self.clock.sleep(for: duration)
            if Task.isCancelled { return }
            self.catDeadlineFired(id: id)
        }
    }

    private func catDeadlineFired(id: UUID) {
        guard var inFlight = catInFlight, inFlight.id == id else { return }
        if inFlight.command.isIdempotent && !inFlight.timeoutRetried {
            // One retry for idempotent commands.
            inFlight.timeoutRetried = true
            inFlight.deadlineTask = makeCATDeadline(id: id,
                                                    after: commandDeadline)
            catInFlight = inFlight
            let data = Data(inFlight.command.wire.utf8)
            Task { try? await self.transport.writeCAT(data) }
            return
        }
        lastTimedOutPrefix = inFlight.command.replyPrefix
        catInFlight = nil
        inFlight.continuation.resume(
            throwing: CATBridgeError.timedOut(command: inFlight.command.wire))
    }

    private func failCAT(id: UUID, error: CATBridgeError) {
        guard let inFlight = catInFlight, inFlight.id == id else { return }
        inFlight.deadlineTask?.cancel()
        catInFlight = nil
        inFlight.continuation.resume(throwing: error)
    }

    private func failCATInFlight(error: CATBridgeError) {
        if let inFlight = catInFlight {
            inFlight.deadlineTask?.cancel()
            catInFlight = nil
            inFlight.continuation.resume(throwing: error)
        }
    }

    private func resolveCAT(reply: String) {
        guard let inFlight = catInFlight else { return }
        inFlight.deadlineTask?.cancel()
        catInFlight = nil
        inFlight.continuation.resume(returning: reply)
    }

    private func routeCATFrame(_ frame: String) {
        if var inFlight = catInFlight {
            if frame == "?;" {
                // Yaesu uses ?; for busy as well as invalid: retry once for
                // idempotent commands (§5.5).
                if inFlight.command.isIdempotent && !inFlight.busyRetried {
                    inFlight.busyRetried = true
                    inFlight.deadlineTask?.cancel()
                    let id = inFlight.id
                    inFlight.deadlineTask = Task {
                        try? await self.clock.sleep(
                            for: self.policy.busyRetryDelay)
                        if Task.isCancelled { return }
                        self.resendCAT(id: id)
                    }
                    catInFlight = inFlight
                } else {
                    let command = inFlight.command.wire
                    failCAT(id: inFlight.id,
                            error: .radioRejected(command: command))
                }
                return
            }
            if let prefix = inFlight.command.replyPrefix,
               frame.hasPrefix(prefix) {
                resolveCAT(reply: frame)
                return
            }
            handleUnsolicited(frame)
            return
        }
        if let prefix = lastTimedOutPrefix, frame.hasPrefix(prefix) {
            // Late reply to a timed-out command: discard so it cannot
            // resolve the next command with stale data (§5.4).
            lastTimedOutPrefix = nil
            return
        }
        handleUnsolicited(frame)
    }

    private func resendCAT(id: UUID) {
        guard var inFlight = catInFlight, inFlight.id == id else { return }
        inFlight.deadlineTask = makeCATDeadline(id: id, after: commandDeadline)
        catInFlight = inFlight
        let data = Data(inFlight.command.wire.utf8)
        Task { try? await self.transport.writeCAT(data) }
    }

    private func handleUnsolicited(_ frame: String) {
        guard let dialect, let value = dialect.parseUnsolicited(frame) else {
            return
        }
        apply(value)
        publish()
    }

    private func apply(_ value: CATValue) {
        switch value {
        case let .frequency(f):
            model.frequency = f
        case let .mode(m):
            model.mode = m
        case let .ptt(on):
            model.isTransmitting = on
        case let .sMeter(v):
            model.sMeter = v
        case let .info(info):
            model.frequency = info.frequency
            if let mode = info.mode { model.mode = mode }
            if let tx = info.isTransmitting { model.isTransmitting = tx }
        case .id, .raw:
            break
        }
    }

    // MARK: - CTRL command execution

    private func acquireCtrl() async {
        if !ctrlBusy {
            ctrlBusy = true
            return
        }
        await withCheckedContinuation { ctrlWaiters.append($0) }
    }

    private func releaseCtrl() {
        if ctrlWaiters.isEmpty {
            ctrlBusy = false
        } else {
            ctrlWaiters.removeFirst().resume()
        }
    }

    private func performCtrl(_ frame: CtrlFrame) async throws -> CtrlReply {
        await acquireCtrl()
        defer { releaseCtrl() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ctrlInFlight = CtrlInFlight(id: id, op: frame.op,
                                            continuation: continuation)
                ctrlInFlight?.deadlineTask = Task {
                    try? await self.clock.sleep(for: self.policy.ctrlDeadline)
                    if Task.isCancelled { return }
                    self.ctrlDeadlineFired(id: id)
                }
                let encoded = frame.encoded
                Task {
                    do {
                        try await self.transport.writeCtrl(encoded)
                    } catch {
                        self.failCtrl(id: id, error: .connectionLost)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelCtrl(id: id) }
        }
    }

    private func cancelCtrl(id: UUID) {
        guard let inFlight = ctrlInFlight, inFlight.id == id else { return }
        inFlight.deadlineTask?.cancel()
        ctrlInFlight = nil
        inFlight.continuation.resume(throwing: CancellationError())
    }

    private func ctrlDeadlineFired(id: UUID) {
        guard let inFlight = ctrlInFlight, inFlight.id == id else { return }
        ctrlInFlight = nil
        inFlight.continuation.resume(
            throwing: CATBridgeError.timedOut(command: "CTRL"))
    }

    private func failCtrl(id: UUID, error: CATBridgeError) {
        guard let inFlight = ctrlInFlight, inFlight.id == id else { return }
        inFlight.deadlineTask?.cancel()
        ctrlInFlight = nil
        inFlight.continuation.resume(throwing: error)
    }

    private func failCtrlInFlight(error: CATBridgeError) {
        if let inFlight = ctrlInFlight {
            inFlight.deadlineTask?.cancel()
            ctrlInFlight = nil
            inFlight.continuation.resume(throwing: error)
        }
    }

    private func resolveCtrl(_ reply: CtrlReply) {
        guard let inFlight = ctrlInFlight else { return }
        inFlight.deadlineTask?.cancel()
        ctrlInFlight = nil
        inFlight.continuation.resume(returning: reply)
    }

    private func routeCtrl(_ data: Data) {
        ctrlRxBuffer.append(data)
        for frame in CtrlFrame.decodeStream(&ctrlRxBuffer) {
            let reply = CtrlReply(frame: frame)
            switch reply {
            case let .ack(forOp), let .nak(forOp, _):
                if let inFlight = ctrlInFlight, inFlight.op == forOp {
                    resolveCtrl(reply)
                }
            case .statusAnswer:
                if let inFlight = ctrlInFlight,
                   inFlight.op == CtrlOp.getStatus.rawValue {
                    resolveCtrl(reply)
                }
            case let .usbEvent(state, radio):
                handleUSBEvent(state: state, radio: radio)
            case let .overflow(direction, dropped):
                handleOverflow(direction: direction, dropped: dropped)
            case .unknown:
                break
            }
        }
    }

    private func handleUSBEvent(state usbState: BridgeUSBState,
                                radio: BridgeRadioID) {
        switch usbState {
        case .enumerated:
            usbEnumerated = true
            failsafeArmed = false // firmware cleared it on the detach
            emit(.usbRadioAttached(radio))
            if dialect != nil {
                Task { try? await self.ensureFailsafeArmed() }
            }
        case .waiting, .error, .unknown:
            usbEnumerated = false
            failsafeArmed = false
            model.isTransmitting = false
            failCATInFlight(error: .usbRadioDisconnected)
            // The bridge reports ERROR with a non-none radio id when a
            // device is attached that it could not open for CAT.
            if case .error = usbState, radio != .none {
                emit(.usbDeviceUnsupported(radio))
            } else {
                emit(.usbRadioDetached)
            }
            publish()
        }
    }

    private func handleOverflow(direction: OverflowDirection,
                                dropped: UInt32) {
        // The stream lost bytes: any partial reply is unusable (§5.5).
        demux.reset()
        failCATInFlight(error: .bridgeOverflow(direction))
        emit(.bridgeOverflow(direction, dropped: dropped))
    }

    // MARK: - Event loop / reconnect (§6)

    private func eventLoop() async {
        for await event in transport.events {
            switch event {
            case .connected, .mtuChanged:
                break
            case let .disconnected(reason):
                handleDisconnect(reason: reason)
            case let .catData(data):
                for frame in demux.ingest(data) {
                    routeCATFrame(frame)
                }
            case let .ctrlFrame(data):
                routeCtrl(data)
            case let .statusData(data):
                if let status = try? BridgeStatus(decoding: data) {
                    model.bridge = BridgeHealth(status: status)
                    publish()
                }
            }
        }
    }

    private func handleDisconnect(reason: String?) {
        guard !userDisconnected else { return }
        pollerTask?.cancel()
        watchdogTask?.cancel()
        failCATInFlight(error: .connectionLost)
        failCtrlInFlight(error: .connectionLost)
        failsafeArmed = false
        demux.reset()
        ctrlRxBuffer.removeAll()
        // The firmware failsafe unkeys the radio on link loss (§7.4).
        model.isTransmitting = false
        setPhase(.reconnecting(attempt: 1))
        if reconnectTask == nil {
            reconnectTask = Task { await self.reconnectLoop() }
        }
    }

    private func reconnectLoop() async {
        var attempt = 1
        var delay = policy.reconnectMinDelay
        defer { reconnectTask = nil }
        while !Task.isCancelled {
            setPhase(.reconnecting(attempt: attempt))
            try? await clock.sleep(for: delay)
            if Task.isCancelled || userDisconnected { return }
            do {
                try await transport.connect()
                try await initializeLink()
                return
            } catch {
                attempt += 1
                delay = min(delay * 2, policy.reconnectMaxDelay)
            }
        }
    }

    // MARK: - Poller (§5.6)

    private func startPoller() {
        pollerTask?.cancel()
        pollerTask = Task { await self.pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await clock.sleep(for: policy.pollInterval)
            if Task.isCancelled { return }
            // User commands take priority over polling.
            guard !slotBusy, slotWaiters.isEmpty else { continue }
            await pollOnce()
        }
    }

    private func pollOnce() async {
        guard case .ready = model.connection, usbEnumerated,
              let dialect else { return }
        // try? flattens execute's String? — nil means threw OR no reply.
        if let reply = try? await execute(dialect.readInfo),
           let value = try? dialect.parse(reply: reply, to: dialect.readInfo) {
            apply(value)
        }
        if let readPTT = dialect.readPTT,
           let reply = try? await execute(readPTT),
           let value = try? dialect.parse(reply: reply, to: readPTT) {
            apply(value)
        }
        if !model.isTransmitting,
           dialect.capabilities.contains(.sMeter),
           let readSMeter = dialect.readSMeter,
           let reply = try? await execute(readSMeter),
           let value = try? dialect.parse(reply: reply, to: readSMeter) {
            apply(value)
        }
        publish()
    }

    // MARK: - PTT watchdog (§7.4)

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            try? await self.clock.sleep(for: self.policy.pttWatchdog)
            if Task.isCancelled { return }
            await self.watchdogFired()
        }
    }

    private func watchdogFired() async {
        guard model.isTransmitting, let dialect else { return }
        _ = try? await execute(dialect.pttOff)
        model.isTransmitting = false
        publish()
        emit(.pttWatchdogTripped)
    }
}
