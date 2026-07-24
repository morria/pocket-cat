# Completeness Report — CAT Bridge System

**Date:** 2026-07-24 · **Scope:** everything on `main` (`f5c4ccf`)
**Question under investigation:** can an iOS app, using our library, easily
read state from and send commands to each of our three target transceivers
(FT-891, FTX-1, QMX) through the ESP32-S3 BLE bridge?

## 1. Executive answer

**Yes, to the strongest level verifiable without hardware — with one radio
(FTX-1) explicitly provisional and all physical-layer claims awaiting bench
bring-up.**

Every layer of the stack exists, builds, and passes its tests in CI: the
ESP32-S3 firmware (compiled for the real target by ESP-IDF v5.3), the
Python bench tools, and the Swift package (`CATBridgeKit`). The iOS library's
*full* connect → identify → poll → command → PTT → failsafe → reconnect
lifecycle runs against scripted FT-891, FTX-1, and QMX radios in 56 Swift
tests, wire-compatible with the firmware by construction (a shared golden
vector file is byte-compared across both codebases in CI).

What no amount of simulation can prove: the system has **never touched a
real radio, a real XIAO board, or a real iPhone**. Section 5 ranks exactly
which assumptions are load-bearing.

## 2. The "easily" test — what an app actually writes

The complete state-and-control loop for any of the three radios:

```swift
import CATBridgeKit

let central = CATBridgeCentral()                    // one per app
let bridge = await central.bridges().first { _ in true }!
let session = try await central.connect(to: bridge) // scans, pairs, probes
                                                    // baud, picks dialect,
                                                    // arms failsafe — done

// State: bind SwiftUI directly to the @Observable object…
Text(session.state.frequency?.description ?? "—")
// …or consume value snapshots anywhere:
for await snap in await session.snapshots() { … }

// Commands:
try await session.setFrequency(.megahertz(14.250))
try await session.setMode(.cw)
try await session.transmit()   // failsafe-interlocked
try await session.receive()
```

The app never sees BLE UUIDs, TLV frames, CAT dialects, baud rates, `;`
terminators, or retry policy. Radio differences surface only through
`session.capabilities` (e.g. the QMX correctly reports no S-meter and no RF
power control) and `state.radio`. This meets the plan's bar for "any iOS app
should be able to interact with this library."

## 3. Per-radio completeness

| Capability | FT-891 | QMX | FTX-1 |
|---|---|---|---|
| Detected via bridge `radio_id` | ✅ CP2105 `0xEA70` | ✅ CDC-ACM class | ✅ generic CP210x (by design) |
| Identity confirmed via `ID;` | ✅ `ID0650;` | ✅ `ID020;` | ⚠️ placeholder `ID0800;` — real code unknown until hardware |
| Baud negotiation | ✅ 38400→9600→4800 walk, incl. factory-default-4800 case | ✅ skipped (native USB, correctly) | ✅ walk (assumed CP210x) |
| Read frequency / mode / PTT / meter | ✅ (9-digit FA, MD0, TX;, SM0) | ✅ (11-digit FA, MD, IF-flag PTT — `TX;` correctly never polled) | ⚠️ Yaesu dialect assumed |
| Set frequency / mode | ✅ | ✅ | ⚠️ assumed |
| PTT with failsafe interlock | ✅ `TX1;`/`TX0;` | ✅ `TX;`/`RX;` | ⚠️ assumed |
| Keyer text | ✅ `KY` | ✅ `KY ` (untested against sim) | ⚠️ assumed |
| Verified against | scripted personality | scripted personality | *placeholder* personality |

The FTX-1 column is honest engineering posture, not an oversight: the radio's
USB identity and `ID;` code are unconfirmable without hardware (firmware plan
open question #1). The design isolates that risk — `YaesuDialect` is
parameterized, the detect table routes unknown CP210x devices to it, and a
generic-ID fallback (`RadioModel.generic`) keeps an unrecognized Yaesu usable.

## 4. Verification matrix — what is proven, and at what level

| Layer | Proof level | Evidence |
|---|---|---|
| Wire format (CTRL TLV + STATUS) | **Cross-implementation, byte-exact** | one golden JSON, consumed by pytest (55 ✅) + Swift tests, `cmp`'d in CI |
| Firmware logic (rings, coalescer, detect, bridge core) | **Host-tested + simulated e2e** | 57 C tests under ASan/UBSan incl. byte-perfect transparency journaling, failsafe, overflow, 1000-cmd soak |
| Firmware compile for esp32s3 | **CI-built, artifact produced** | ESP-IDF v5.3 job green |
| iOS core (codec, dialects, demux, session actor) | **Unit + integration-simulated** | 56 Swift tests: mode-table matrices, demux fuzz, 21 session tests incl. kill-app-mid-PTT → firmware-failsafe unkey, reconnect + re-arm, cancellation, `?;`-busy |
| iOS BLE adapter | **Compiles (macOS + iOS simulator) + 3 constant/shape tests** | thinnest layer, weakest coverage — by design, but see §5 |
| Anything on physical hardware | **Nothing** | no radio, XIAO, or iPhone has been connected |

Supporting invariants that hold end-to-end in simulation: byte-perfect
transparency (the bridge never corrupts the stream), exactly-one-reply CTRL
semantics, arm-before-key failsafe ordering (journal-proven on both the C and
Swift sides), and stale-data protection (late-reply discard, BLE-absent purge).

## 5. Gaps, ranked by risk

**Blocking real-world use (hardware bring-up items — all pre-documented):**

1. **VBUS power path** on the XIAO (esp32s3 refs): measure `5V`↔VBUS before
   anything else; a bus-powered CP2105 that never enumerates is the #1 trap.
2. **CP2105 Enhanced-interface assumption** (`RD_FT891_CAT_IFACE = 0`): if CAT
   is actually on the other UART, the FT-891 silently doesn't answer.
3. **Yaesu/Kenwood `IF;` field offsets**: parsers match our simulators, which
   match our documentation — but not yet a real rig. A shifted offset breaks
   mode/PTT display (not safety; PTT-off paths don't depend on IF).
4. **FTX-1 identity end-to-end** (USB descriptor, `ID;`, dialect deltas).
5. **iOS pairing/bonding UX** against the firmware's encryption requirement,
   and background-mode behavior — CoreBluetooth is only lightly fake-tested.

**Missing deliverables promised by the plan (non-blocking):**

6. `iOS/docs/api-guide.md` (plan M4) — not written.
7. **DocC catalog** (plan §2) — public symbols have doc comments, but no
   `.docc` bundle or tutorial; the CI DocC step was never added.
8. **Example app / compiling SwiftUI snippet** (M4 acceptance) — none.
9. `swift package diagnose-api-breaking-changes` baseline — deferred until a
   v0.1 tag exists (plan M7), which it doesn't yet.

**Known compromises (acceptable, documented):**

10. BLE adapter tests are 3 shape checks, not the delegate-order fakes the
    plan sketched (§9.3) — the layer is thin and simulator-compile-checked,
    but a regression in, say, notify-subscription ordering would only show on
    hardware.
11. Swift personalities duplicate `radio_sim.py` (drift surfaces on the bench
    rig, which runs the Python originals).
12. `ManualClock.pump` relies on generous task-yielding; theoretically
    schedule-sensitive, empirically stable in CI so far.

## 6. Milestone scorecard

**Firmware plan (M0–M8):** M0–M5 complete to their non-hardware acceptance
criteria (M5's bonding config is implemented and compiled; its BLE test cases
need the bench). M6–M8 (real-radio acceptance, FTX-1, soak/RF) are
hardware-gated by definition.

**iOS plan (M0–M7):** M0–M3 complete. M4 partial (BLE transport ✅ +
simulator build ✅; api-guide ✗, fuller adapter tests ✗). M5–M6 hardware-gated.
M7 (DocC tutorial, API baseline, v0.1 tag) not started.

## 7. Bottom line and recommended next steps

The software is done to the edge of what software alone can prove: **a
developer can add one SPM dependency and, in ~15 lines, observe and control
an FT-891 or QMX through the bridge — with the FTX-1 expected to work and
designed to degrade gracefully if its identity differs.** Every safety
property we could encode (failsafe ordering, PTT interlock, watchdog) is
enforced in code and locked by tests on both sides of the BLE link.

In order:

1. **Bench bring-up** (highest information per hour): flash the XIAO, run
   `radio_sim.py` on a CP2102, drive with `ble_client.py` — this validates
   the entire BLE+USB path with zero radios. Then the CP2105 eval board, then
   real radios per the acceptance checklists.
2. Close the cheap plan debts: api-guide.md, DocC catalog + CI step, a
   minimal SwiftUI example app (doubles as the manual-QA harness for #1's
   iOS leg).
3. After the first green bench pass: tag firmware + library v0.1, wire the
   API-breaking-changes baseline.
4. FTX-1 bring-up when hardware is available; expect only the ID table and
   possibly IF offsets to change.
