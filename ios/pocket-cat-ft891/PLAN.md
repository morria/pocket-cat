# FT-891 Pocket — Design, Implementation & Test Plan

An iOS app for full CAT control of the Yaesu FT-891 over the Pocket Cat BLE
bridge (`../..`, `CATBridgeKit`). Native SwiftUI, HIG-conformant,
iOS 17+.

Research grounding (read these first):

| Doc | Contents |
|---|---|
| [docs/pocket-cat-integration.md](docs/pocket-cat-integration.md) | CATBridgeKit surface, raw-command semantics, safety model |
| [docs/ft891-cat-commands.md](docs/ft891-cat-commands.md) | Full 60-command CAT reference, IF layout, quirks |
| [docs/ft891-menus.md](docs/ft891-menus.md) | All 159 menu items with EX encodings, names, UI subtext |
| [docs/state-of-the-art.md](docs/state-of-the-art.md) | Competitive landscape, UI patterns, config-backup precedents |

## 1. Product definition

**Positioning.** No iOS app can control an FT-891 today (Yaesu's own iOS
story requires SCU-LAN10 hardware the FT-891 doesn't support; USB serial and
Bluetooth SPP are closed on stock iOS). Pocket Cat's BLE bridge is the
practical path, and this app is its first-party front end.

**V1 scope (from requirements):**

1. **Operate** — frequency, mode, RF power, antenna-tuner control, PTT,
   metering (S / PO / SWR / ALC), plus the near-frequency controls that make
   those usable: band select, clarifier, split, A/B VFO.
2. **Settings** — every one of the 159 menu items, presented with
   plain-English names and explanatory subtext (content already authored in
   `docs/ft891-menus.md`), organized, searchable, and editable in place.
3. **Profiles** — capture the radio's full configuration (all writable menu
   items + operating state) to a named, versioned JSON file in iCloud Drive;
   load a profile, preview the diff against the live radio, and apply it.

**Deliberately out of v1:** audio (BLE can't carry it), spectrum scope,
memory-channel programming (MW/MR round-trips are a large surface; the
profile schema reserves a `memories` key so v1.5 can add it without a format
break), CW free-text keying (the FT-891's `KY` only plays stored memories),
macros/logging.

## 2. Architecture

```
┌──────────────  SwiftUI views (Operate / Settings / Profiles)  ─────────────┐
│                          @Observable view state                            │
├─────────────────────────  RigStore (@MainActor)  ──────────────────────────┤
│  app-level observable state: power, tuner, meters, menu cache, profiles    │
├──────────────────────────  FT891Kit (app target)  ─────────────────────────┤
│  MenuCatalog: 159-item semantic table over readMenuItem/setMenuItem        │
│  Raw-command wrappers for the residue (AC, RM, CF/RD/RU, ST, BS, RS…)      │
│  ProfileEngine: read-all sweep · diff · ordered apply                      │
│  RigSession protocol  ──  live: CATBridgeKit  │  sim: FT891SimTransport    │
├───────────────────────────  CATBridgeKit (SPM)  ───────────────────────────┤
│  session actor · BLE transport · baud probe · failsafe · IF/TX/SM polling  │
│  typed: freq · mode · PTT · power · RigSetting catalog · EX menu access    │
└────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 FT891Kit — the FT-891 semantic layer

CATBridgeKit's typed API now covers most of the rig surface directly:
frequency/mode/PTT/S-meter, **`readPower`/`setPower` (validated 5–100 W,
`state.power`)**, a **`RigSetting` catalog** (AF/RF gain, squelch, mic gain,
keyer speed, break-in, NB, NR, preamp, attenuator, narrow, filter width —
with per-setting feature detection and validated ranges), and **EX menu
access** (`readMenuItem`/`setMenuItem`, raw digit-string values, gated on
`.menuAccess`). See `docs/pocket-cat-integration.md`.

FT891Kit is what remains, by design:

- **`MenuCatalog`** — the semantic table the library deliberately doesn't
  own (one entry per menu item): `id ("05-06")`, `exNumber ("0506")`, group,
  official name, friendly name, subtext, value type (`bool`,
  `enumerated([...])`, `int(range:step:unit:)`, `signedInt`,
  `indexCoded(map:)`), default, digit count, and `isWritable` (18-xx and
  17-01 excluded from profile writes). It encodes engineering values to the
  digit strings `setMenuItem` expects and decodes reads back. Source of
  truth is `docs/ft891-menus.md`; a generator script keeps the Swift table
  honest against the doc (§5.1).
- **Raw-command wrappers** for the small untyped residue: antenna tuner
  (`AC`), RM meters (SWR/ALC/PO), clarifier (`CF/RD/RU/RC`), split (`ST`),
  band select (`BS`), VFO ops (`SV/AB/BA`), busy (`BY`), menu-mode detect
  (`RS`) — exact formats from `docs/ft891-cat-commands.md`; reads pass
  `isIdempotent: true`.
- **Signed-EX workaround**: 11 menu items carry a mandatory `+`/`-`
  (`EX0513`, `EX0517`, `EX0803/04`, `EX1202`, `EX1502/05/08`,
  `EX1511/14/17`); the library's `setMenu`/`parseMenu` validate digits-only
  and reject them. Preferred: one-line upstream fix relaxing the validation
  (we control both repos); until merged, MenuCatalog routes these 11 via
  `rawCommand`.
- **`RigSession` protocol** — the seam the app talks through; live
  implementation backed by `TransceiverSession`, simulated one for tests
  and previews (§5.2). Views and stores never import CoreBluetooth.

Broadly useful residue (AC, RM) can still graduate upstream into
`YaesuDialect`; the app does not block on library changes.

### 2.2 Polling & write discipline

- Library poller owns IF/TX/SM at 2 Hz (turn `enableAutoInformation` **on**
  for near-instant panel-knob feedback; poller remains the backstop).
- Power is handled by the library (read once per connect, kept fresh by
  `setPower` and AI pushes). App-level secondary polling is screen-scoped:
  `RM` SWR/ALC/PO at ~4 Hz only while transmitting or tuning; `AC` and
  visible `RigSetting`s refreshed on screen appearance and after writes.
  Idle screens add zero traffic.
- Frequency scrubbing coalesces: at most one in-flight `FA` set, latest value
  wins (drop intermediate values, never queue a backlog).
- Menu writes are guarded by `RS;` — if the operator is inside the
  front-panel menu, the app pauses writes and tells the user why (Set
  behavior in that state is undocumented).

### 2.3 Profiles & iCloud

- **Format:** versioned JSON — `{schemaVersion, savedAt, radioFirmware,
  name, notes, operating: {frequencyA/B, mode, power, split, clarifier},
  menu: {"01-01": value, …}}`. Values stored in engineering units (not raw
  EX encodings) so files are human-readable and survive encoding fixes.
- **Storage:** the app's iCloud Drive ubiquity container (documents visible
  in the Files app), enumerated with `NSMetadataQuery`; plus
  `.fileImporter`/`ShareLink` so profiles can live anywhere and be shared.
  No CloudKit database — files match the user's mental model and FTRestore
  precedent.
- **Capture:** EX sweep of all writable items + operating state. At 38400 baud
  this is a few seconds; at 4800 it can approach a minute — always run it
  behind a determinate progress view with cancel.
- **Apply:** diff first (FTRestore's proven workflow): show exactly which
  items will change, current → new, grouped like the Settings screen. Apply
  writes only the diff, in catalog order, re-reading each item to confirm;
  failures are collected and reported per-item, never silently skipped.
  Radio state (freq/mode/power) applies last.

## 3. UI design (HIG-native)

Three tabs + a persistent connection status affordance.

### 3.1 Operate

- **Frequency display** — large monospaced digits (`.monospacedDigit`,
  SF Pro Rounded), the centerpiece. Three tuning inputs, matching the
  state-of-the-art convergence:
  1. vertical swipe on any digit tunes that decade (with `.adjustable`
     VoiceOver trait);
  2. a horizontal scrub wheel below the display with haptic detents
     (`UIImpactFeedbackGenerator` per step, step size follows mode-appropriate
     menu 14-xx steps);
  3. tap the display → direct-entry keypad sheet.
- **Mode** — horizontal segmented picker (LSB USB CW … DATA-USB), showing the
  full `OperatingMode` table; band strip (1.8–50 MHz + GEN) using `BS`.
- **Meters** — one bar meter, S-meter in RX, switches to PO/SWR/ALC cluster in
  TX; peak-hold; raw 0–255 mapped with the calibration tables noted in the
  CAT doc.
- **RF power** — slider bound to `session.powerRange` (5–100 W) with a
  numeric field, writes `setPower(watts:)` on release (not continuously).
- **RX chain quick controls** — AF/RF gain, squelch, NB/NR, preamp (IPO/AMP
  only — clamp the library's 0–2 field to 0–1), attenuator, narrow/width:
  all via the typed `RigSetting` API in a compact controls drawer.
- **Tuner** — button showing tuner state (`AC`): off / on / tuning. Starting a
  tune cycle (`AC002;`) keys the transmitter, so it gets a confirmation step
  ("Tune will transmit a carrier — continue?"), a prominent in-progress state
  with live SWR, and requires menu 16-15 to be set (surface guidance if the
  radio rejects).
- **PTT** — deliberate control: press-and-hold to talk with a distinct lock
  gesture; giant, unmissable TX state (screen edge glow + red status); the
  library's failsafe + watchdog backstop it.
- **Secondary row** — clarifier (CF/RD/RU/RC), split (ST), A/B (SV/AB/BA),
  VFO A/B swap.

### 3.2 Settings (the 159 menu items)

- Grouped `List` mirroring the radio's 18 groups but with friendly section
  names ("CW Keyer", "TX Audio", …). Each row: **friendly name** headline,
  **subtext description** (both already written in `docs/ft891-menus.md`),
  current value trailing; official menu number + name shown as a footnote in
  the editor so front-panel veterans can cross-reference.
- Editors by value type: `Toggle` for on/off, `Picker` (navigation-link
  style) for enumerated, `Stepper`+`Slider` with units for numeric, signed
  steppers for offsets. Values write through immediately (EX set + re-read
  to confirm) with an inline saving/failed indicator.
- `.searchable` across friendly name, official name, menu number, and
  description text — "notch", "07-05", "sidetone" all hit.
- A "Modified from default" filter (catalog knows the defaults) — the fastest
  answer to "what have I changed?".

### 3.3 Profiles

- List of iCloud profiles (name, date, radio firmware, notes preview).
- **Save Current Configuration** → progress sheet (sweep) → name/notes.
- Tap a profile → detail with **Compare with Radio** (diff view) and
  **Apply** (diff preview → confirm → progress → per-item results).
- Swipe actions: rename, duplicate, share (`ShareLink`), delete.

### 3.4 Connection & system UX

- First-run scan sheet (bridges by RSSI), pairing flow, persisted
  auto-reconnect via `connect(id:)`; CoreBluetooth state restoration +
  `bluetooth-central` background mode.
- `ConnectionPhase` surfaced as a compact status capsule; `bridgeReady`
  (bridge up, radio silent) gets specific guidance: check CAT RATE (05-06),
  CAT RTS (05-08), cable. `bondInvalidated` → "Forget device in Settings"
  walkthrough. `radio_sim`-style disconnect storms must land back gracefully.
- Dark-mode-first visual design (shack at night), full light-mode support,
  Dynamic Type throughout, VoiceOver labels/values on every control, haptics
  on detents and TX transitions.

## 4. Implementation milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M0 | Xcode project, SPM dep on `../..`, CI (build + test), app icon/theme scaffold; upstream PR: signed-EX validation fix | CI green |
| M1 | FT891Kit: MenuCatalog (all 159, incl. signed/index codecs) + catalog generator check + raw-command wrappers (AC/RM/CF/ST/BS/RS…) | unit suite green; catalog matches docs |
| M2 | FT891SimTransport (FT-891 personality incl. full EX table; start from pocket-cat's test `RadioPersonality`) + RigSession seam | full app runnable against sim; previews work |
| M3 | Connection UX + Operate screen (freq/mode/band/meters) | end-to-end against sim |
| M4 | Power, tuner cycle, PTT, clarifier/split | safety flows reviewed; watchdog/failsafe paths exercised |
| M5 | Settings screen, all editors, search, modified-filter | every item editable against sim |
| M6 | ProfileEngine + iCloud documents + diff/apply UI | round-trip and diff tests green |
| M7 | Accessibility, haptics, dark/light polish, error-guidance pass | HIG self-audit checklist |
| M8 | **Hardware bring-up** with real bridge + FT-891 | §5.4 checklist signed off |

M2 before any UI is deliberate: the simulator personality makes every later
milestone demoable, previewable, and testable without hardware — the same
philosophy pocket-cat used.

## 5. Testing strategy

### 5.1 Unit (fast, headless, CI)

- **Codecs:** golden vectors for the MenuCatalog value codecs (sign handling
  incl. `-00`, index-coded values like LCUT `00–19`) and the raw-command
  wrappers, transcribed from the CAT reference. Property fuzz: random reply
  bytes never crash a parser. (The PC/RigSetting/EX wire layer is covered by
  pocket-cat's own suite — don't re-test the library.)
- **MenuCatalog integrity:** a generator/checker script parses
  `docs/ft891-menus.md` and asserts the Swift table matches (count, EX
  numbers, ranges, defaults) — documentation and code cannot drift.
- **Round-trips:** engineering value → EX wire → parsed value is identity for
  every item; profile JSON encode/decode round-trips; schema-version
  migration stub tested.
- **Diff engine:** synthetic radio states → expected diffs, including
  unknown-key tolerance (forward compatibility).

### 5.2 Integration against the simulated rig

`FT891SimTransport` implements CATBridgeKit's `BridgeTransport` with an
FT-891 personality (command tables ported from pocket-cat's
`radio_sim.py`, extended with EX for all catalog items and quirk faults:
`?;`-busy bursts, mute, garbage, disconnects, `RS1;` menu-mode).

- Full connect → identify → ready → operate flows.
- Profile capture → wipe sim → apply → sim state equals capture.
- Interrupted apply (disconnect mid-sweep) → resumable, accurate per-item
  report.
- Tuning scrub coalescing (no FA backlog), poller/user-command priority.
- PTT: interlock ordering, watchdog trip surfaces in UI state.

### 5.3 UI

- XCUITest smoke: connect (sim), tune, change mode, edit a menu item, save +
  apply a profile.
- Snapshot tests of Operate/Settings/Profiles in light/dark and at
  accessibility text sizes.

### 5.4 Hardware acceptance (manual checklist, real FT-891 + bridge)

1. Baud matrix: CAT RATE 4800/9600/19200/38400 all connect via the probe.
2. **Verify `IF;` field offsets against the real rig** (pocket-cat flags its
   layout as simulator-derived) — first item on the bench.
3. EX sweep timing at 4800 and 38400; progress UX acceptable at both.
4. Full profile save → factory reset (17-01) → profile apply → radio state
   matches (spot-check the manual's two known default ambiguities: 14-06,
   16-07/16-08).
5. Tune cycle into a dummy load: confirmation, TX indication, SWR display,
   completion state; behavior when 16-15 unset.
6. PTT into dummy load; kill the app mid-TX → firmware failsafe unkeys.
7. Front-panel interaction: turn the physical dial (AI pushes update the
   display), enter the front-panel menu (`RS1;` pauses writes with
   guidance).
8. Reconnect storms: BT off/on, walk out of range, bridge power-cycle.
9. Verify [UNVERIFIED] items from the CAT doc on hardware (framing, `?;`
   behavior, CAT RTS deafness, APF encoding) and update the docs.

## 6. Risks & open questions

- **IF offsets / simulator-vs-rig drift** — mitigated by M8 item 2 and by
  keeping app-side wire knowledge in FT891Kit + docs.
- **Signed-EX items rejected by the library's typed menu API** (11 items) —
  upstream fix in M0; rawCommand fallback keeps us unblocked either way.
- **EX behavior while radio is in front-panel menu mode** is undocumented —
  mitigated by the `RS;` guard; verify on hardware.
- **4800-baud profile sweeps are slow** — mitigated by progress UI and by
  recommending (in-app guidance) CAT RATE 38400.
- **Manual contradictions** (14-06, 16-07/16-08 defaults; EX0905 digit typo)
  — resolve on hardware, then correct docs and catalog.
- Power on/off (`PS`) has known timing quirks (dummy bytes, 1–2 s) — nice to
  have, decide after bring-up.
- App Store name/branding TBD ("FT-891 Pocket" working title; avoid Yaesu
  trademark issues in the listing).
