// Session integration tests (docs/implementation.md §9.2): the REAL
// TransceiverSession actor against scripted radio personalities with a
// manual clock — headless, deterministic, no sleeps.

import Foundation
import Testing
@testable import CATBridgeCore

/// Builds a session + transport + clock trio for one scenario.
struct Rig {
    let transport: ScriptedTransport
    let clock: ManualClock
    let session: TransceiverSession

    init(radio: RadioPersonality, radioID: BridgeRadioID,
         initialBaud: UInt32 = 4800, policy: PollingPolicy = .default) {
        transport = ScriptedTransport(radio: radio, radioID: radioID,
                                      initialBaud: initialBaud)
        clock = ManualClock()
        session = TransceiverSession(transport: transport, clock: clock,
                                     policy: policy)
    }

    /// Start the session while pumping the manual clock so probe deadlines
    /// and pollers can make progress.
    func start(pumping duration: Duration = .seconds(5)) async throws {
        let session = self.session
        let startTask = Task { try await session.start() }
        await clock.pump(duration)
        try await startTask.value
    }

    func snapshot() async -> TransceiverSnapshot {
        var iterator = await session.snapshots().makeAsyncIterator()
        return await iterator.next() ?? TransceiverSnapshot()
    }
}

@Suite struct SessionConnectTests {
    @Test func ft891FullConnectFlow() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        #expect(snap.radio == .ft891)
        #expect(snap.frequency == Frequency(hz: 14_074_000))
        #expect(snap.mode == .cw)
        #expect(snap.bridge.baud == 38400) // probe negotiated up from 4800

        // Failsafe was armed (ACKed) before ready (§7.4).
        let armed = await rig.transport.armedFailsafe()
        #expect(armed == Data("TX0;".utf8))
        let caps = await rig.session.capabilities
        #expect(caps.contains(.sMeter))
    }

    @Test func qmxConnectSkipsBaudProbe() async throws {
        let rig = Rig(radio: QmxPersonality(), radioID: .qmxCDC)
        try await rig.start()

        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        #expect(snap.radio == .qmx)
        #expect(snap.frequency == Frequency(hz: 14_074_000))
        // No SET_BAUD walk for native-USB radios: at most zero setBaud
        // ctrl entries before the failsafe arm.
        let journal = await rig.transport.journal
        let baudChanges = journal.filter {
            if case .ctrl(CtrlOp.setBaud.rawValue, _) = $0 { return true }
            return false
        }
        #expect(baudChanges.isEmpty)
        let armed = await rig.transport.armedFailsafe()
        #expect(armed == Data("RX;".utf8))
    }

    @Test func baudProbeWalksDownToRadioSetting() async throws {
        let radio = Ft891Personality()
        radio.menuBaud = 4800 // factory-fresh radio: CAT RATE 4800
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start(pumping: .seconds(10))

        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        #expect(snap.bridge.baud == 4800)
    }

    @Test func silentRadioSurfacesButBridgeStaysUsable() async throws {
        let radio = Ft891Personality()
        radio.muted = true
        let rig = Rig(radio: radio, radioID: .ft891)
        let session = rig.session
        let startTask = Task {
            do {
                try await session.start()
                return false
            } catch {
                return (error as? CATBridgeError) == .radioNotResponding
            }
        }
        await rig.clock.pump(.seconds(20))
        #expect(await startTask.value)
        let snap = await rig.snapshot()
        #expect(snap.connection == .bridgeReady)
    }

    @Test func ftx1CandidateAdoptsGenericYaesu() async throws {
        let rig = Rig(radio: Ftx1Personality(), radioID: .genericCP210x)
        try await rig.start()
        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        #expect(snap.radio == .ftx1) // exact ID0800; match adopts the model
    }
}

@Suite struct SessionCommandTests {
    @Test func setAndReadFrequency() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        try await rig.session.setFrequency(Frequency(hz: 7_030_000))
        let read = try await rig.session.readFrequency()
        #expect(read == Frequency(hz: 7_030_000))
    }

    @Test func setModeQMXKenwoodCodes() async throws {
        let rig = Rig(radio: QmxPersonality(), radioID: .qmxCDC)
        try await rig.start()
        try await rig.session.setMode(.usb)
        let journal = await rig.transport.journal
        #expect(journal.contains(.cat("MD2;")))
    }

    @Test func timeoutThenRetrySucceedsForIdempotent() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start()

        // Mute exactly one response: first FA; goes unanswered, the retry
        // after the deadline is answered.
        await rig.transport.setStallAfter(0)
        let session = rig.session
        let readTask = Task { try await session.readFrequency() }
        await rig.clock.pump(.seconds(2))
        let value = try await readTask.value
        #expect(value == Frequency(hz: 14_074_000))
    }

    @Test func nonIdempotentIsNotRetried() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start()

        let before = await rig.transport.journal.filter {
            $0 == .cat("KYTEST;")
        }.count
        #expect(before == 0)
        try await rig.session.send(keyerText: "TEST")
        let after = await rig.transport.journal.filter {
            $0 == .cat("KYTEST;")
        }.count
        #expect(after == 1) // sent exactly once, no retry machinery
    }

    @Test func questionMarkBusyRetriesOnce() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start()

        // An unknown-to-the-radio idempotent command draws "?;" each time:
        // the session must retry once, then surface radioRejected.
        let session = rig.session
        let task = Task {
            try await session.rawCommand("ZZ;", expectsReply: true,
                                         isIdempotent: true)
        }
        await rig.clock.pump(.seconds(2))
        await #expect(throws: CATBridgeError.radioRejected(command: "ZZ;")) {
            _ = try await task.value
        }
        let sends = await rig.transport.journal.filter { $0 == .cat("ZZ;") }
        #expect(sends.count == 2) // original + single busy retry
    }

    @Test func cancelledCommandIsNeverSent() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        // Occupy the slot with a command that will time out (muted radio),
        // queue a second command behind it, cancel the second.
        await rig.transport.setMuted(true)
        let session = rig.session
        let first = Task { try await session.readFrequency() }
        for _ in 0..<50 { await Task.yield() }
        let second = Task { try await session.setFrequency(.megahertz(7.0)) }
        for _ in 0..<50 { await Task.yield() }
        second.cancel()
        await rig.clock.pump(.seconds(5))
        _ = try? await first.value
        _ = try? await second.value

        let journal = await rig.transport.journal
        #expect(!journal.contains(.cat("FA007000000;")))
    }
}

@Suite struct SessionPTTTests {
    @Test func failsafeArmedBeforeFirstPTT() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()
        try await rig.session.transmit()

        let transmitting = await rig.transport.isTransmitting()
        #expect(transmitting)

        // Journal ordering: SET_FAILSAFE precedes the first TX1; (§9.2).
        let armIndex = await rig.transport.journalIndex {
            if case .ctrl(CtrlOp.setFailsafe.rawValue, _) = $0 {
                return true
            }
            return false
        }
        let keyIndex = await rig.transport.journalIndex { $0 == .cat("TX1;") }
        let arm = try #require(armIndex)
        let key = try #require(keyIndex)
        #expect(arm < key)

        try await rig.session.receive()
        let after = await rig.transport.isTransmitting()
        #expect(!after)
    }

    @Test func appDeathMidTransmitUnkeysViaFirmwareFailsafe() async throws {
        // The system-level test that matters most (§9.4 item 3), scripted:
        // key PTT, then hard-drop the BLE link. The transport emulates the
        // firmware emitting the armed failsafe → the radio must unkey.
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start()
        try await rig.session.transmit()
        #expect(radio.transmitting)

        await rig.transport.dropLink()
        for _ in 0..<50 { await Task.yield() }
        #expect(!radio.transmitting) // firmware failsafe unkeyed it

        let snap = await rig.snapshot()
        #expect(!snap.isTransmitting)
    }

    @Test func rawPTTWithoutArmedFailsafeThrows() async throws {
        let rig = Rig(radio: QmxPersonality(), radioID: .qmxCDC)
        try await rig.start()
        // Simulate the armed flag being lost: fire the failsafe by dropping
        // and reconnecting is heavy — instead use the interlock directly:
        // a fresh session arms at ready, so force-disarm via a scripted USB
        // detach event (firmware clears failsafe on detach).
        await rig.transport.injectCtrl(
            CtrlFrame(op: CtrlOp.evtUSB.rawValue, payload: Data([0, 0])))
        for _ in 0..<50 { await Task.yield() }
        await #expect(throws: (any Error).self) {
            _ = try await rig.session.rawCommand("TX;", expectsReply: false)
        }
    }

    @Test func pttWatchdogTripsLoudly() async throws {
        var policy = PollingPolicy.default
        policy.pttWatchdog = .seconds(30)
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891, policy: policy)
        try await rig.start()

        let session = rig.session
        let eventsTask = Task { () -> SessionEvent? in
            for await event in await session.events() {
                if event == .pttWatchdogTripped { return event }
            }
            return nil
        }
        for _ in 0..<50 { await Task.yield() }

        try await rig.session.transmit()
        #expect(radio.transmitting)
        await rig.clock.pump(.seconds(35))

        #expect(!radio.transmitting) // watchdog sent TX0;
        let event = await eventsTask.value
        #expect(event == .pttWatchdogTripped) // loud, never silent (§7.4)
        let snap = await rig.snapshot()
        #expect(!snap.isTransmitting)
    }
}

@Suite struct SessionRobustnessTests {
    @Test func reconnectAfterLinkDropReachesReadyAndRearms() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        await rig.transport.dropLink()
        await rig.clock.pump(.seconds(10)) // backoff + reconnect + re-init

        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        let armed = await rig.transport.armedFailsafe()
        #expect(armed == Data("TX0;".utf8)) // re-armed after reconnect
    }

    @Test func overflowEventFailsInFlightCommand() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        await rig.transport.setMuted(true) // command will hang in flight
        let session = rig.session
        let task = Task { try await session.readFrequency() }
        for _ in 0..<50 { await Task.yield() }
        await rig.transport.injectCtrl(
            CtrlFrame(op: CtrlOp.evtOverflow.rawValue,
                      payload: Data([0, 10, 0, 0, 0])))
        for _ in 0..<50 { await Task.yield() }
        await #expect(throws: CATBridgeError.bridgeOverflow(.usbToBLE)) {
            _ = try await task.value
        }
    }

    @Test func unsolicitedFramesFoldIntoState() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()

        await rig.transport.injectCAT("FA021074000;") // AI-mode style push
        for _ in 0..<50 { await Task.yield() }
        let snap = await rig.snapshot()
        #expect(snap.frequency == Frequency(hz: 21_074_000))
    }

    @Test func pollerTracksRadioSideChanges() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        try await rig.start()

        radio.vfoA = "028074000" // operator turns the dial
        await rig.clock.pump(.seconds(2)) // a few poll cycles
        let snap = await rig.snapshot()
        #expect(snap.frequency == Frequency(hz: 28_074_000))
    }

    @Test func dripFedRepliesReassemble() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891)
        await rig.transport.setResponseChunkSize(1) // 1-byte BLE dribble
        try await rig.start()
        let read = try await rig.session.readFrequency()
        #expect(read == Frequency(hz: 14_074_000))
    }

    @Test func connectRetriesAfterInitialFailure() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        await rig.transport.setFailConnects(1)
        let session = rig.session
        let startTask = Task { try? await session.start() }
        await rig.clock.pump(.seconds(2))
        _ = await startTask.value
        // First start() throws (connect failed); a second start succeeds.
        try await rig.start()
        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
    }
}

@Suite struct AutoInformationTests {
    static var aiPolicy: PollingPolicy {
        var policy = PollingPolicy.default
        policy.enableAutoInformation = true
        return policy
    }

    @Test func optInEnablesAIAndPushesAreInstant() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891, policy: Self.aiPolicy)
        try await rig.start()

        #expect(await rig.transport.isAIEnabled())
        let journal = await rig.transport.journal
        #expect(journal.contains(.cat("AI1;")))

        // Operator turns the dial. NO clock advance: the poller cannot run,
        // so an updated frequency proves the PUSH path, not polling.
        await rig.transport.turnDial(to: "021074000")
        for _ in 0..<50 { await Task.yield() }
        let snap = await rig.snapshot()
        #expect(snap.frequency == Frequency(hz: 21_074_000))
    }

    @Test func defaultPolicyNeverSendsAI() async throws {
        let rig = Rig(radio: Ft891Personality(), radioID: .ft891)
        try await rig.start()
        let journal = await rig.transport.journal
        #expect(!journal.contains(.cat("AI1;")))
        #expect(!(await rig.transport.isAIEnabled()))

        // Dial turns are invisible until the next poll (backstop behavior).
        await rig.transport.turnDial(to: "021074000")
        for _ in 0..<50 { await Task.yield() }
        var snap = await rig.snapshot()
        #expect(snap.frequency == Frequency(hz: 14_074_000))
        await rig.clock.pump(.seconds(2)) // now the poller catches it
        snap = await rig.snapshot()
        #expect(snap.frequency == Frequency(hz: 21_074_000))
    }

    @Test func optInIsIgnoredForRadiosWithoutAI() async throws {
        let rig = Rig(radio: QmxPersonality(), radioID: .qmxCDC,
                      policy: Self.aiPolicy)
        try await rig.start()
        let snap = await rig.snapshot()
        #expect(snap.connection == .ready) // flag is harmless on QMX
        let journal = await rig.transport.journal
        #expect(!journal.contains(.cat("AI1;")))
    }

    @Test func reconnectReenablesAI() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891, policy: Self.aiPolicy)
        try await rig.start()
        #expect(await rig.transport.isAIEnabled())

        // Radio side loses AI state across the drop (fresh power-on rigs
        // default AI off); the session must re-enable it on reconnect.
        await rig.transport.dropLink()
        radio.aiEnabled = false
        await rig.clock.pump(.seconds(10))

        let snap = await rig.snapshot()
        #expect(snap.connection == .ready)
        #expect(await rig.transport.isAIEnabled())
        let enables = await rig.transport.journal.filter { $0 == .cat("AI1;") }
        #expect(enables.count == 2) // initial + post-reconnect
    }

    @Test func disconnectPolitelyDisablesAI() async throws {
        let radio = Ft891Personality()
        let rig = Rig(radio: radio, radioID: .ft891, policy: Self.aiPolicy)
        try await rig.start()
        #expect(await rig.transport.isAIEnabled())

        await rig.session.disconnect()
        let journal = await rig.transport.journal
        #expect(journal.contains(.cat("AI0;")))
        #expect(!(await rig.transport.isAIEnabled()))
    }
}
