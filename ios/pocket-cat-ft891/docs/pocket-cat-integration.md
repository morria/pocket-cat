# Pocket Cat / CATBridgeKit — Integration Reference

How this app talks to the FT-891: through the `CATBridgeKit` Swift package
at the repo root (BLE↔USB bridge on a XIAO ESP32-S3 plugged into the
radio's USB CAT port). This doc summarizes the library surface as of the
version we build against, and what the app must layer on top.

## Topology

```
FT-891 app ────(SwiftUI/@Observable)── CATBridgeKit
                                            │ BLE GATT (bonded, encrypted)
                                    XIAO ESP32-S3 bridge (dumb pipe)
                                            │ USB host → CP2105
                                        FT-891 CAT port
```

All CAT protocol knowledge lives on the phone. The bridge only shuttles
bytes, negotiates baud on command, and enforces a dead-man PTT failsafe.

## Package

- `import CATBridgeKit` (SPM, `../..`, swift-tools 6.0, iOS 17+ /
  macOS 14+, Swift 6 strict concurrency).
- Targets: `CATBridgeCore` (pure logic, testable headless) +
  `CATBridgeBLE` (CoreBluetooth transport).

## Connection lifecycle

```swift
let central = CATBridgeCentral()                  // app owns exactly one
for await bridge in central.bridges() { … }       // scan (service-UUID)
let session = try await central.connect(to: bridge)   // or connect(id:) for
                                                      // persisted reconnect
```

`connect` drives the link to `ready`: reads bridge STATUS, walks baud
38400→9600→4800 probing `ID;` (expects `ID0650;` for FT-891), selects
`YaesuDialect.ft891`, arms the `TX0;` failsafe, starts the poller.
`ConnectionPhase`: `idle / connecting / bridgeReady / identifyingRadio /
ready / reconnecting(attempt:) / failed`. Auto-reconnect with backoff is
built in; `bridgeReady` means "bridge OK, no radio answering" (app should
show CAT RATE / cable guidance).

Pass `restorationIdentifier:` to `CATBridgeCentral` + the app's
`bluetooth-central` background mode for CoreBluetooth state restoration.

## Observable state (bind SwiftUI directly)

`session.state` is `@MainActor @Observable TransceiverState`:

| Property | Type | Fed by |
|---|---|---|
| `connection` | `ConnectionPhase` | lifecycle |
| `radio` | `RadioModel?` (`.ft891`) | ID probe |
| `frequency` | `Frequency?` (integer Hz) | `IF;` poll / AI push |
| `mode` | `OperatingMode?` | `IF;` poll / AI push |
| `isTransmitting` | `Bool` | `TX;` poll |
| `sMeter` | `Int?` (raw 0–255 `SM0` units) | `SM0;` poll (RX only) |
| `power` | `Int?` (watts) | read once at connect, `setPower`, AI pushes |
| `bridge` | `BridgeHealth` (baud, drops, fw, heap) | STATUS |

Non-UI consumers use `session.snapshots()` (`AsyncStream` of value
snapshots) and `session.events()` for out-of-band events:
`pttWatchdogTripped`, `bridgeOverflow`, `usbRadioAttached/Detached`,
`usbDeviceUnsupported`.

## Typed control surface (what the library gives us)

```swift
try await session.setFrequency(Frequency(hz: 14_250_000))  // FA, 9-digit Hz
try await session.setMode(.cw)                             // MD0<code>;
try await session.transmit()    // TX1; — refuses unless failsafe armed
try await session.receive()     // TX0;
try await session.send(keyerText: "CQ CQ")                 // KY
let f = try await session.readFrequency()

// RF power (PC) — snapshot.power filled at connect, kept fresh by AI
let watts = try await session.readPower()
try await session.setPower(watts: 100)     // validated vs powerRange 5...100

// Settings catalog — per-setting feature detection, validated ranges
session.supportedSettings                  // Set<RigSetting>
session.range(of: .afGain)                 // 0...255
let ag = try await session.read(.afGain)   // AG0;
try await session.set(.keyerSpeed, to: 22) // KS022;

// Yaesu EX menu access — raw digit strings, semantics are app-side
let v = try await session.readMenuItem("0506")        // CAT RATE index
try await session.setMenuItem("0506", value: "3")     // 38400 baud

session.capabilities            // [.frequencyControl, .modeControl, .ptt,
                                //  .sMeter, .keyerText, .rfPowerControl,
                                //  .autoInformation, .menuAccess] for FT-891
```

`RigSetting` covers: afGain (`AG0`, 0–255), rfGain (`RG0`, 0–255), squelch
(`SQ0`, 0–100), micGain (`MG`, 0–100), keyerSpeed (`KS`, 4–60), breakIn
(`BI`), noiseBlanker (`NB0`), noiseReduction (`NR0`), preamp (`PA0`, 0–2),
attenuator (`RA0`), narrow (`NA0`), filterWidth (`SH0`, 0–21). Booleans are
0/1; out-of-range sets throw before touching the radio.

Menu values are deliberately **untyped digit strings** — the 159-item
semantic catalog (names, subtext, ranges, index↔label maps, engineering
units) is the app's job (`docs/ft891-menus.md`).

`OperatingMode` covers the full FT-891 table: lsb, usb, cw, cwReverse, fm,
fmNarrow, am, amNarrow, rtty, rttyReverse, dataLSB, dataUSB, dataFM,
dataFMNarrow, c4fm.

`PollingPolicy` (pass to `connect`): poll interval (default 500 ms `IF;` +
`TX;` + `SM0;`), command deadlines, `enableAutoInformation` (off by
default — turn ON: `AI1;` gives near-instant pushes; poller stays as
backstop), `pttWatchdog` (default 180 s).

## The raw escape hatch (what still needs it)

After the typed-API expansion, the remaining untyped surface is small:
**antenna tuner (`AC`), RM meters (SWR/ALC/PO), clarifier (`CF/RD/RU/RC`),
split (`ST`), band select (`BS`), VFO ops (`SV/AB/BA/VS`), busy (`BY`),
menu-mode detect (`RS`), memories (`MC/MW/MR…`)** — plus the 11
signed-value EX items (see caveats). The sanctioned path:

```swift
let ac = try await session.rawCommand("AC;", expectsReply: true)   // "AC001;"
try await session.rawCommand("AC002;", expectsReply: false)        // tune cycle
let swr = try await session.rawCommand("RM6;", expectsReply: true)
```

Semantics to respect:

- Commands serialize through the session actor (one in flight) — raw
  commands share the queue with the poller and typed calls; no interleaving
  hazards.
- `expectsReply: true` matches replies by the **first two characters** of
  the wire string (`"EX0301;"` → prefix `"EX"`). Works for all FT-891
  read commands.
- `isIdempotent: false` by default → no automatic retry on timeout or
  `?;`-busy. Pass `isIdempotent: true` for reads so they get the one-retry
  policy.
- `?;` replies surface as `CATBridgeError.radioRejected`. The radio also
  answers `?;` when *busy* (e.g. during tune), not just for invalid
  commands.
- PTT-on via raw is refused while the failsafe is unarmed (interlock).
- Set commands answer with silence — confirmation is the next poll.

**Design consequence:** the app's FT891Kit shrinks to (a) thin raw-command
wrappers for the commands above, (b) the MenuCatalog semantic layer over
`readMenuItem`/`setMenuItem`, and (c) the ProfileEngine. Broadly useful
pieces (AC, RM) can still graduate upstream into `YaesuDialect`.

## Safety model (why the app can key 100 W remotely)

1. BLE bonding (LE Secure Connections) required before any write.
2. `SET_FAILSAFE "TX0;"` armed before `ready`; firmware unkeys on link
   loss/app death. Re-armed automatically after reconnect / USB re-attach.
3. Session-side PTT watchdog (default 3 min) unkeys if the app forgets —
   fires loudly via `session.events()`.
4. `disconnect()` politely restores `AI0;`.

The app must still: keep PTT a deliberate gesture, show TX state
prominently, and stop TX before entering states that can't display it.

## Errors worth first-class UI

`CATBridgeError`: `bluetoothUnavailable`, `bridgeNotFound`,
`pairingRequired`, `bondInvalidated` (bridge re-flashed → "Forget device"
guidance), `usbRadioDisconnected`, `radioNotResponding` (baud walk failed →
check CAT RATE menu 05-06 / cable), `radioRejected` (`?;`),
`timedOut(command:)`, `bridgeOverflow`, `pttInterlock`, `notReady`.

## Known caveats (from pocket-cat docs)

- **Signed EX values don't pass the typed menu API**: `setMenu` and
  `parseMenu` validate digits-only, but 11 FT-891 items carry a mandatory
  `+`/`-` sign (`EX0513`, `EX0517`, `EX0803/04`, `EX1202`, `EX1502/05/08`,
  `EX1511/14/17` — see `docs/ft891-menus.md` note 3). Until the library
  relaxes the validation (one-line upstream fix), read/write these via
  `rawCommand("EX0513…", …)`.
- `RigSetting` overlaps the EX menu for nothing — settings are front-panel
  controls (gains, NB/NR, width), menus are EX; no double-write hazard.
- `preamp` range is the wire field's (0–2); the FT-891 only has IPO(0)/
  AMP(1) — sending 2 gets `?;` from the radio, so clamp to 0–1 in UI.

- The `IF;` fixed offsets in `YaesuDialect` match the project's simulators
  but carry a **bring-up caveat against the real rig** — verify on hardware
  early (pocket-cat `docs/completeness-report.md`).
- Real-radio bring-up (FT-891) had not yet happened as of the version
  read; firmware verified over the air, radio path only against
  `radio_sim.py`.
- Factory-fresh FT-891 has CAT RATE 4800 (slow; 1 s command deadline).
  Recommend users set menu 05-06 CAT RATE to 38400; the baud probe adapts
  either way. Menu 05-08 CAT RTS should be DISABLE (bridge may not assert
  RTS).
- Useful pocket-cat references: `esp32s3/docs/references/yaesu-cat-ft891.md`
  (CAT subset + IF layout), `esp32s3/docs/protocol.md` (BLE GATT, normative),
  `docs/ios-implementation.md` (library design), `esp32s3/test/tools/
  radio_sim.py` (FT-891 personality — reusable for app integration tests).
