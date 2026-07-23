# CATBridgeKit — iOS Library Implementation Plan

## 1. Purpose and Scope

A Swift library (**CATBridgeKit**) that lets any iOS app control a transceiver
— **Yaesu FT-891, Yaesu FTX-1, QRP Labs QMX** — through the ESP32-S3 BLE↔USB
CAT bridge, and read its state.

The division of labor is fixed by the system design
(`esp32s3/docs/implementation.md` §1): the bridge is a dumb pipe; **all CAT
protocol knowledge lives here**. This library therefore owns:

1. The BLE link to the bridge (its GATT contract is normative in
   [`esp32s3/docs/protocol.md`](../../esp32s3/docs/protocol.md)).
2. The bridge control plane (CTRL TLV, STATUS, failsafe, baud negotiation).
3. The CAT dialects (Yaesu ASCII for FT-891/FTX-1, Kenwood TS-480 subset for
   QMX) — command encoding, response parsing, polling.
4. A typed, observable transceiver model apps bind UI to.

Non-goals (v1): audio, waterfall/spectrum, rig memory management, CW paddle
timing (a system non-goal — see esp32s3 plan §1), multi-radio simultaneous
sessions, watchOS/tvOS, and **split/VFO-B operation** (state models VFO-A
only in v1; `IF;` already carries what a later split feature needs, so this
is scope control, not an architectural door closing).

**Platforms:** iOS 17+, macOS 14+ (macOS matters: it lets the entire test
suite run under `swift test` on CI without a simulator, and enables a future
Mac app for free). Swift 6 language mode, strict concurrency.

## 2. Idiomatic-Apple Ground Rules

What "as Apple pushes engineers to implement libraries" means concretely:

- **Swift Package Manager** package, no other distribution formats.
- **Swift 6 strict concurrency**: everything public is `Sendable`; mutable
  state lives in **actors**; UI-facing state uses **`@Observable`**
  (Observation framework) so SwiftUI views bind directly.
- **`async/await`** for commands; **`AsyncStream`/`AsyncSequence`** for
  continuous data (state updates, connection events, raw CAT taps).
- **Structured errors**: one `CATBridgeError` enum tree conforming to
  `LocalizedError`; no `NSError` bridging in the public surface.
- **Dependency inversion at the OS boundary**: CoreBluetooth is hidden
  behind a `BridgeTransport` protocol; the library never exposes `CBPeripheral`.
- **Swift API Design Guidelines** naming (`connect(to:)`, `setFrequency(_:)`,
  fluency at the call site).
- **DocC** documentation catalog with articles + tutorials; every public
  symbol documented.
- **Swift Testing** (`@Test`, `#expect`) — Apple's current test framework —
  not XCTest, except where XCTest is unavoidable (none anticipated).
- **`os.Logger`** with subsystem `radio.catbridge`, privacy-annotated.

## 3. Package Layout

```
iOS/
├── docs/
│   ├── implementation.md          # this file
│   └── api-guide.md               # written at M4: integration guide for apps
└── CATBridgeKit/
    ├── Package.swift              # swift-tools 6.0; iOS 17 / macOS 14
    ├── Sources/
    │   ├── CATBridgeCore/         # ZERO-dependency pure logic (no CoreBluetooth)
    │   │   ├── Ctrl/              #   TLV codec, Status, opcodes  (protocol.md §2–3)
    │   │   ├── CAT/               #   dialects, parsers, values (Frequency, Mode…)
    │   │   └── Session/           #   TransceiverSession actor, poller, cmd queue
    │   └── CATBridgeBLE/          # CoreBluetooth transport (depends on Core)
    ├── Tests/
    │   ├── CATBridgeCoreTests/    # unit + scripted-radio integration tests
    │   └── CATBridgeBLETests/     # CB delegate plumbing tests w/ fakes
    └── Sources/CATBridgeCore/Documentation.docc/
```

Two targets on purpose: **`CATBridgeCore` must not import CoreBluetooth** —
that is what makes ~95 % of the library runnable under plain `swift test` on a
Linux-less macOS CI runner and in previews. `CATBridgeBLE` is a thin adapter.

## 4. Public API (the shape apps see)

```swift
import CATBridgeKit

// 0. ONE CBCentralManager for the process, owned by the library.
//    CoreBluetooth peripherals are only usable by the central that
//    discovered them, so scanning and connecting MUST share a central —
//    a scanner and a session with separate managers is a broken design.
let central = CATBridgeCentral()            // long-lived; app owns one

// 1. Discover bridges (each advertises the service UUID; protocol.md §1)
for await found in central.bridges() {      // AsyncStream<DiscoveredBridge>
    // found.name == "CATBridge-3F2A", found.rssi, found.id (UUID)
}

// 2. Connect — returns a ready session or throws a typed error.
//    Also accepts a persisted identifier (UserDefaults) for auto-reconnect
//    on later launches via retrievePeripherals(withIdentifiers:).
let session = try await central.connect(to: found)          // or (id: UUID)

// 3. Observe state (SwiftUI-ready)
@MainActor @Observable public final class TransceiverState {
    public private(set) var connection: ConnectionPhase
    public private(set) var radio: RadioModel?     // .ft891/.ftx1/.qmx/.generic
    public private(set) var frequency: Frequency?  // VFO-A, integer Hz core
    public private(set) var mode: OperatingMode?
    public private(set) var isTransmitting: Bool
    public private(set) var sMeter: SignalLevel?
    public private(set) var bridge: BridgeHealth   // baud, drops, fw, heap
}
session.state          // `nonisolated let`: reference from anywhere,
                       // property access on MainActor (where SwiftUI lives)
session.snapshots      // AsyncStream<TransceiverSnapshot> — an immutable
                       // Sendable VALUE copy per update, for non-UI consumers
                       // (never the mutable reference type across actors)

// 4. Control — async, throws, cancellation-safe
try await session.setFrequency(Frequency(hz: 14_250_000))
try await session.setFrequency(.megahertz(14.250))  // convenience; documented
                                                    // round-to-nearest-Hz
try await session.setMode(.cw)
try await session.transmit()               // failsafe interlock, §7.4
try await session.receive()
let freq = try await session.readFrequency()
try await session.send(keyerText: "CQ CQ DE …")   // where supported

// 5. Capabilities differ per radio — apps query, never guess
if session.capabilities.contains(.rfPowerControl) { … }

// 6. Escape hatch for power users: raw CAT with the same serialization
let reply: Data = try await session.rawCommand("EX0301;", expectsReply: true)
```

Design points:

- `TransceiverSession` is an **actor**. All radio I/O serializes through it —
  that is the concurrency model *and* the CAT correctness model (one in-flight
  command per radio; CAT has no framing to interleave replies).
- `TransceiverState` is `@MainActor @Observable`; the session publishes to it
  by hopping to the main actor per coalesced update. It is exposed as a
  `nonisolated let`, which is safe precisely because every property access is
  MainActor-gated. Cross-actor consumers use `snapshots` (immutable value
  type) — the mutable reference type never crosses an isolation boundary.
- `Frequency` stores **integer hertz** (`UInt64`) — CAT is integer-Hz on the
  wire and `Double` cannot represent 14.250 MHz exactly. Floating-point
  conveniences round to nearest Hz and say so in their docs.
- `TransceiverSession.init(transport: some BridgeTransport, …)` is **public**:
  it is how the test suite injects `ScriptedTransport`, and how an app could
  bring its own transport (e.g. a TCP link to rigctld) without touching BLE.
- Every control call is **cancellable** (Task cancellation propagates to a
  dequeued-or-abandoned command) and has a per-command deadline.
- `RadioModel` derives from the bridge's `STATUS.radio_id` (protocol.md §3),
  refined by the CAT `ID;` reply (`0650` FT-891, `020` TS-480-family QMX,
  FTX-1 TBD — see esp32s3 references). The dialect is selected internally;
  apps never handle dialects directly.
- `central.bridges()` returns a fresh single-consumer stream per call
  (AsyncStream semantics); scanning runs while ≥ 1 stream is active.

## 5. Architecture (layer by layer)

```
┌────────────────────────────  app (SwiftUI / UIKit)  ─────────────────────────┐
│   @Observable TransceiverState        async control methods                  │
├───────────────────────  TransceiverSession (actor)  ─────────────────────────┤
│  command queue (1 in-flight, timeout+retry policy)                           │
│  polling engine (IF; cadence, meters)     failsafe/PTT interlock             │
│  baud negotiation (ID; probe)             dialect selection                  │
├─────────────┬───────────────────────────────┬────────────────────────────────┤
│ CATDialect  │        BridgeControl          │   ResponseDemux                │
│ (Yaesu /    │  CTRL TLV encode/decode       │  ';'-scanner, garbage resync,  │
│  Kenwood)   │  STATUS decode, events        │  unsolicited (AI) handling     │
├─────────────┴───────────────────────────────┴────────────────────────────────┤
│                     BridgeTransport (protocol, Sendable)                     │
│   connect/disconnect · writeCAT · writeCtrl · inbound AsyncStreams · mtu     │
├──────────────────────────────────────────────────────────────────────────────┤
│  BLEBridgeTransport (CoreBluetooth)   │   ScriptedTransport (tests)          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 `BridgeTransport` (the seam that makes everything testable)

```swift
public protocol BridgeTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }   // connected, mtu, catData,
                                                      // ctrlFrame, status, disconnected
    func connect() async throws
    func disconnect() async
    func writeCAT(_ data: Data) async throws          // chunks to ≤ mtu-3 internally
    func writeCtrl(_ frame: Data) async throws        // with-response write
    var maximumCATWriteLength: Int { get async }
}
```

`BLEBridgeTransport` implements it with CoreBluetooth (§7).
`ScriptedTransport` implements it with the Swift port of the radio
personalities (§9.3). The session cannot tell them apart — by construction.

### 5.2 `BridgeControl` — the control plane (pure)

Direct Swift mirror of `esp32s3/test/tools/catproto.py` /
`firmware/components/ctrl_proto`:

- `CtrlFrame` encode/decode (`[op][len][payload]`, LE integers).
- Commands: `setBaud`, `getStatus`, `usbReset`, `setLine`, `purge`,
  `setFailsafe` — each paired with its ACK/NAK/answer rule (protocol.md §2:
  *exactly one reply per command*; GET_STATUS answers with its own opcode).
- `BridgeStatus` decode (22-byte versioned struct) with forward-compatible
  minor-version tolerance: unknown trailing bytes ignored, unknown
  `radio_id` mapped to `.unknown(rawValue:)`, version byte ≠ 1 → typed error.
- Events: `usbEvent(state:radio:)`, `overflow(direction:dropped:)`.

### 5.3 CAT dialects (pure)

```swift
protocol CATDialect: Sendable {
    var terminator: UInt8 { get }                 // ';' for all three
    func readFrequency() -> CATCommand            // encode side
    func setFrequency(_ f: Frequency) -> CATCommand
    func parse(_ response: ArraySlice<UInt8>, for: CATCommand) throws -> CATValue
    func parseUnsolicited(_ frame: ArraySlice<UInt8>) -> CATValue?
    var pttOn: CATCommand { get }                 // TX1; vs TX;
    var pttOff: CATCommand { get }                // TX0; vs RX;   (= failsafe string)
    var capabilities: RadioCapabilities { get }
}
```

- **`YaesuDialect`** (FT-891; FTX-1 subclasses/parameterizes it): 9-digit Hz
  `FA`, `MD0<code>;` with the newcat mode table, `IF;` fixed-width parse,
  `TX1;/TX0;/TX;`, `ID;`→`0650`, meters `SM0;`/`RM`. Mode codes are
  transcribed from `esp32s3/docs/references/yaesu-cat-ft891.md` (grounded in
  Hamlib `newcat_mode_conv[]`) — never from memory.
- **`KenwoodDialect`** (QMX): **11-digit** Hz `FA`, single-digit `MD`,
  `TX;`/`RX;` *without replies*, `ID;`→`020`, TS-480 `IF;` layout.
  QMX capabilities exclude what the radio lacks (e.g. `rfPowerControl`).
- Set-commands that produce **no reply** (both dialects) are modeled
  explicitly: `CATCommand.expectsReply == false` → completion is "bytes
  handed to transport", with the poller confirming effect on the next `IF;`.

### 5.4 `ResponseDemux` — stream discipline

CAT is a byte stream with a single `;` delimiter and **no correlation IDs**.
The demux:

- Accumulates transport bytes, emits `;`-terminated frames.
- **Garbage resync**: on frames failing dialect validation (baud mismatch
  produces binary noise), drop to the next `;` and count
  (`session.diagnostics.garbageFrames`); never crash, never wedge.
- Routes frames: if a command is in flight and the frame's prefix matches the
  expected reply → resolve it; `?;` → typed `CATBridgeError.radioRejected`;
  otherwise → `parseUnsolicited` (Yaesu Auto-Information, late replies after
  a timeout) → folded into state, never into the wrong continuation.
- A late reply arriving *after* its command timed out is recognized (prefix
  match against the last timed-out command within 1 s) and **discarded**, so
  it cannot resolve the *next* command with stale data.

### 5.5 Command queue policy

- One in-flight command; others await in an ordered queue inside the actor.
- Deadline: an **absolute per-command deadline** measured from write
  completion — 500 ms at ≥ 9600 baud, 1 s at 4800. Deliberately *not*
  "time since last transport activity": a radio chattering Auto-Information
  frames would reset an activity-based timer forever and wedge an unanswered
  command. Deadlines come from the injected `Clock` (§9.2), so tests are
  instant and deterministic.
- Retry: one retry for idempotent commands (all reads; frequency/mode sets).
  **Never retry** non-idempotent commands (`KY` keyer text, PTT transitions,
  anything via the raw escape hatch unless the caller opts in).
- **`?;` is not simply "invalid"**: Yaesu rigs also answer `?;` when busy.
  Policy (matching Hamlib's behavior): for an idempotent command, one delayed
  (50 ms) retry; if `?;` repeats, surface `.radioRejected`. Non-idempotent →
  surface immediately.
- Cancellation: a cancelled `Task` removes a queued command; an in-flight
  cancelled command is abandoned (reply discarded by the late-reply rule).
- `EVT_OVERFLOW` from the bridge (protocol.md §2): fail the in-flight
  command with `.bridgeOverflow`, purge demux buffer, let the caller/poller
  re-issue — mirrors the recovery contract in esp32s3 plan §6.

### 5.6 Polling engine

- Cadence: `IF;` at 2 Hz when idle, 5 Hz for 3 s after any set command
  (fast confirmation), plus `SM0;` at 2 Hz while receiving on radios with
  meters. All intervals are constants in one `PollingPolicy` struct —
  injectable for tests and app-tunable within bounds.
- Backs off automatically while a user command is queued (user > poller).
- Suspends when the app backgrounds without an active PTT (§7.4), resumes on
  foreground.

## 6. Connection Lifecycle & Baud Negotiation

State machine (surfaced as `ConnectionPhase` in state):

```
idle → scanning → connecting → discoveringServices → subscribing
     → bridgeReady            (STATUS read OK, fmt version check)
     → identifyingRadio       (radio_id + baud probe)
     → ready
any → reconnecting (backoff 0.5 s→8 s, jittered) → …
```

Baud probe on `bridgeReady` when `radio_id` is a CP210x profile
(FT-891/FTX-1; skipped for QMX — baud is cosmetic there):

1. `SET_BAUD 38400` → `ID;` (600 ms window) → hit? done.
2. else `SET_BAUD 9600` → `ID;` → hit? done.
3. else `SET_BAUD 4800` → `ID;` → hit? done; else surface
   `.radioNotResponding` with the bridge still `ready` (app shows guidance:
   check CAT RATE menu / cable).

`ID;` doubles as model confirmation; a mismatch between `radio_id` (transport
level) and `ID;` (protocol level) prefers `ID;` and logs the discrepancy.

## 7. CoreBluetooth Specifics (`CATBridgeBLE`)

- **Write path**: CAT uses write-without-response, throttled by
  `canSendWriteWithoutResponse` / `peripheralIsReady(toSendWriteWithoutResponse:)`
  (the firmware assumes this — esp32s3 plan §6). CTRL uses write-with-response.
  Chunking to `maximumWriteValueLength(for: .withoutResponse)`.
- **MTU**: read from the peripheral after connect; the session's demux does
  not care (stream-oriented), but write chunking does.
- **Background**: `bluetooth-central` background mode documented as an
  *app-level* opt-in (Info.plist belongs to the app, not the library). State
  restoration via `CBCentralManagerOptionRestoreIdentifierKey` supported when
  the app passes a restoration ID into the `CATBridgeCentral` configuration.
  Restoration (and a few other CB behaviors) is iOS-only → those paths are
  `#if os(iOS)` and compile-checked by the CI simulator build (§9.5).
  Scanning by **service UUID** only (the firmware advertises it precisely so
  background scans work).
- **Bonding**: the firmware requires an encrypted link before CAT/CTRL writes
  (protocol.md §1). iOS surfaces pairing automatically on the first
  encrypted-characteristic access; the library maps the ATT
  insufficient-authentication error into `.pairingRequired` and retries once
  after pairing completes. "Peer removed bond" (firmware re-flashed) maps to
  `.bondInvalidated` with a recovery hint (Settings → Bluetooth → Forget).
- **No CB types in the public API.** `DiscoveredBridge` wraps identifier,
  name, RSSI.

### 7.4 PTT × app lifecycle

PTT is the safety-critical path (mirrors firmware §4.1/§5.5):

- **Arm-once, cached**: the session arms the dialect's failsafe
  (`SET_FAILSAFE "TX0;"` / `"RX;"`, ACK required) when the session reaches
  `ready`, and re-arms whenever the armed state could have been lost — after
  every BLE reconnect, after `EVT_USB(enumerated)` (firmware clears the
  failsafe on USB detach), and after any failsafe fire. `transmit()` then
  only checks the cached armed flag — **zero added latency per key-down**
  (arming per keying would cost a CTRL round-trip on every over).
- The interlock itself is not configurable and not bypassable: if the armed
  flag is unset (e.g. re-arm in flight after a reconnect), `transmit()` arms
  and awaits the ACK before keying; the raw escape hatch refuses PTT-on
  commands (matched against the dialect's encoding) while unarmed.
- `receive()` sends PTT-off and confirms via `IF;`/`TX;`. The failsafe stays
  armed while `ready` (it is idle-cost-free); it is *not* disarmed after each
  over, avoiding an arm/disarm churn window.
- If the app is backgrounded/suspended or the BLE link drops while
  transmitting, the **firmware** failsafe unkeys — the library's job is only
  the arm-before-key ordering guarantee above.
- A `pttWatchdog` (default 3 min, configurable 30 s–5 min, not off) sends
  PTT-off if the app forgets — belt to the firmware's braces. Firing is
  **loud, never silent**: state flips to `isTransmitting = false` with a
  `pttWatchdogTripped` entry in `session.events`, so a legitimate long
  transmission (WSPR is 2 min — the default must clear it) that trips the
  watchdog is visible to the app and the user, not a mystery unkey.

## 8. Error Taxonomy

```swift
public enum CATBridgeError: Error, Sendable {
    case bluetoothUnavailable(BluetoothUnavailableReason)  // off/unauthorized/unsupported
    case bridgeNotFound
    case connectionFailed(underlying: Error?)
    case connectionLost              // → session auto-reconnects; commands fail fast
    case pairingRequired
    case bondInvalidated
    case bridgeRejected(op: CtrlOp, code: CtrlErr)   // NAK passthrough, typed
    case bridgeOverflow(direction: OverflowDirection)
    case usbRadioDisconnected        // EVT_USB detached
    case radioNotResponding          // baud probe exhausted / poll silence
    case radioRejected(command: String)   // "?;"
    case malformedResponse(String)
    case timedOut(command: String)
    case unsupportedCapability(RadioCapability)
    case statusVersionUnsupported(UInt8)
}
```

Every case carries enough context to render user-facing guidance;
`LocalizedError` conformance supplies `errorDescription`/`recoverySuggestion`.

## 9. Testing Strategy

Layered like the firmware's (esp32s3 plan §7): everything below the
CoreBluetooth delegate line runs headless in CI; the thin CB layer is tested
with fakes; real-device checks are a scripted manual pass.

### 9.1 Unit tests (Swift Testing, `CATBridgeCoreTests`)

- **Wire-format golden vectors shared with the firmware — one file, not a
  comment**: a JSON vector file `esp32s3/test/vectors/ctrlproto.json`
  (frames, STATUS payloads, expected decodes) becomes the single source of
  truth. The Python suite loads it directly; the Swift package embeds a copy
  as an SPM resource (SPM cannot reference files outside the package root)
  and a CI step **byte-compares the two copies** — so the "duplicate" cannot
  drift silently, which a pinning comment never guarantees. Swift Testing
  consumes it via `@Test(arguments:)` over the decoded vector list.
- **Dialect encoders**: parameterized tests over the full mode tables (Yaesu
  newcat codes incl. `8`/`A`–`F` data modes; Kenwood single digits),
  frequency zero-padding at 9 vs 11 digits, boundary frequencies.
- **Dialect parsers**: `IF;` fixed-width parse for both layouts; `?;`; short/
  long/garbage frames; property-style fuzz (random bytes → parser never
  crashes, always resyncs).
- **Demux**: frames split across arbitrary chunk boundaries (1-byte drip,
  MTU-sized, straddling `;`), interleaved unsolicited frames, the
  late-reply-after-timeout discard rule.
- **BridgeControl**: TLV round-trips, truncated frames, unknown opcodes,
  status forward-compatibility (extra bytes / unknown radio_id).

### 9.2 Session integration tests (still headless, still fast)

`ScriptedTransport` drives the *real* `TransceiverSession` actor against
Swift ports of the three radio personalities from
`esp32s3/test/tools/radio_sim.py` (same command→response tables, same fault
injections — mute, stall-mid-response, garbage burst, disconnect). The port
is acknowledged duplication: it pins the radio_sim revision it mirrors in a
header comment, and the on-device rig (§9.4) runs against the *Python*
personalities, so a behavioral drift between the two shows up there rather
than never:

- Full connect → identify → ready flow per radio; dialect auto-selection.
- Baud-probe walk (38400 → 9600 → 4800) incl. all-fail surfacing.
- Command round-trips, no-reply set commands confirmed by next poll.
- Timeout → single retry → success; non-idempotent commands not retried.
- Cancellation: cancelled Task's command never sent / reply discarded.
- PTT interlock (§7.4): failsafe is armed (ACKed) before `ready`; the
  transport journal proves SET_FAILSAFE precedes the first PTT-on; re-arm
  happens after scripted reconnect and after `EVT_USB(enumerated)`; a
  `transmit()` racing an in-flight re-arm awaits the ACK before keying;
  raw-escape-hatch PTT while unarmed → throws.
- PTT watchdog: manual-clock advance past the deadline → PTT-off sent,
  `pttWatchdogTripped` event emitted (never a silent unkey).
- Overflow event → in-flight command fails, poller recovers state.
- Reconnect storm: scripted disconnects at every lifecycle phase; state
  machine always lands back in `ready` or a terminal error, never wedges.
- Deterministic time: the session takes a `Clock` (swift-clocks style
  injectable `any Clock<Duration>`); tests use a manual clock — **no
  `sleep`-based flakiness**.

### 9.3 BLE adapter tests (`CATBridgeBLETests`)

`BLEBridgeTransport` is written against tiny protocols
(`CentralManaging`, `PeripheralConnecting`) that `CBCentralManager`/
`CBPeripheral` conform to via extensions; fakes simulate delegate callback
sequences: connect flows, MTU values, notify delivery order,
`didUpdateValueFor` re-entrancy, write-without-response backpressure
(`canSend` toggling), state restoration payloads, ATT authentication errors.
This layer stays so thin that these tests are mostly plumbing-order checks.

### 9.4 On-device acceptance (manual, scripted checklist — `docs/testing-acceptance.md`)

With the real bridge + `radio_sim.py` rig (no radio), then real radios:

1. Discover, pair (bonded build), reconnect after app kill, after BT toggle.
2. Background: lock phone mid-poll → resumes; state restoration relaunch.
3. PTT on FT-891 into dummy load: key, kill the app mid-TX → **radio unkeys
   via firmware failsafe** (the system-level test that matters most).
4. Baud menu matrix on FT-891 (4800/9600/38400 CAT RATE).
5. QMX end-to-end: WSJT-X-style freq/mode flow.
6. Latency feel: frequency step scrubbing ≥ 5 cmd/s sustained.

### 9.5 CI

GitHub Actions `macos-latest`:

1. `swift build -c release` + `swift test` (Core + BLE fakes) — runs the
   whole headless suite natively on macOS.
2. **iOS simulator build** (`xcodebuild build -scheme CATBridgeKit
   -destination 'generic/platform=iOS Simulator'`): macOS-only compilation
   never touches iOS-only code (`#if os(iOS)` branches like CB state
   restoration — `CBCentralManagerOptionRestoreIdentifierKey` does not exist
   on macOS), so without this step those branches are unchecked until
   someone opens Xcode. Build-only; the fakes already test the logic.
3. Golden-vector byte-compare against `esp32s3/test/vectors/ctrlproto.json`
   (§9.1).
4. `swift package diagnose-api-breaking-changes` against the last tag once
   v0.1 is cut; DocC build with zero missing-symbol warnings.

## 10. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M0 | Package scaffold, CI, DocC skeleton, error taxonomy | CI green on empty-ish package |
| M1 | BridgeControl (TLV/STATUS) + golden-vector tests | §9.1 control-plane tests green |
| M2 | Dialects + demux + parsers | §9.1 dialect/demux tests green |
| M3 | TransceiverSession actor + ScriptedTransport + personalities | §9.2 suite green |
| M4 | BLE transport + adapter tests + api-guide.md | §9.3 green; example SwiftUI app snippet compiles |
| M5 | On-device pass with bridge + radio_sim rig | §9.4 items 1–2, 6 |
| M6 | Real-radio pass (FT-891, QMX), failsafe kill-test | §9.4 items 3–5 |
| M7 | API review vs Swift guidelines, DocC tutorial, tag v0.1 | api-breaking-changes baseline |

## 11. Open Questions

1. FTX-1 `ID;` code and dialect deltas — blocked on hardware (same open
   question as firmware M7); `YaesuDialect` parameterization holds the slot.
2. Whether to expose a `Combine` bridge for legacy UIKit apps, or stay
   AsyncSequence-only (lean: stay async-only; Combine adapters are trivial
   for apps to write).
3. Minimum deployment: confirm iOS 17 floor is acceptable for the target
   apps; dropping to 16 forfeits `@Observable` (fallback: ObservableObject).
4. Localization of `LocalizedError` strings — ship English-only in v0.1 with
   String Catalog scaffolding?
