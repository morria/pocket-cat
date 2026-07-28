# Passband Strip — Build Instructions

**Status:** not built · **Scope:** `ios/pocket-cat-ft891` only · **Design:**
[`rig-control-ux.md`](rig-control-ux.md) §3

One spatial control replacing four sliders: drag the passband to shift it,
drag an edge to change width, tap to drop a notch, drag the contour handle
to reshape. The design rationale is in the UX doc; this is how to build it,
and — more importantly — **what has to be established on a bench first.**

This is FT-891-only by nature. The QMX has no IF shift, no manual notch and
no contour, and its `FW` is read-only (`esp32s3/docs/references/qmx-cat.md`).

---

## 1. Read this before writing code

The repo's Yaesu reference is an **explicit subset**:

> …commands incl. memory channels `MC`, `MW`, menu `EX`, CTCSS/DCS, etc.
> Treat…
> — `esp32s3/docs/references/yaesu-cat-ft891.md:78`

`IS`, `BP` and `CO` are **not** documented there. Everything in §2 below is a
question to answer against the *FT-891 CAT Operation Reference Manual* and a
real radio, not a specification to code against. Guessing a field width here
does not produce a compile error — it produces a write that silently reshapes
someone's receiver, or a `?;` rejection loop.

**Update 2026-07-28:** §2's *format* questions are now researched and
documented in `yaesu-cat-ft891.md` ("Passband commands" section), sourced
from Hamlib's `is_ft891` branches — the de-facto tested implementation for
this rig family. Each answer is marked below. What remains for the bench is
**verification plus the behavioural questions** (§2.6): confirm each format
with one command on a real radio before the UI ships writes, and mark the
reference doc rows verified as you go.

---

## 2. Unknowns to resolve on the bench

Each of these should end up as a row in the CAT reference doc, with the
answer and the date it was verified.

### 2.1 IF shift — `IS`

| Question | Why it matters |
|---|---|
| Exact wire format | **ANSWERED** (Hamlib): `IS0` + on-digit (`0` iff value 0) + `%+.4d` → `IS01+0250;`, clear `IS00+0000;`. Read `IS0;` |
| Units and range | **ANSWERED**: Hz, ±1200 |
| Step granularity | **BENCH**: panel steps 20 Hz; whether CAT rounds is unverified — assume snap-to-20 in UI until measured |
| Does `IS;` read back? | **ANSWERED**: yes, `IS0;`, same shape |
| Mode-dependent? | **BENCH**: assume rejected in AM/FM (other Yaesus are); UI disables there regardless |

### 2.2 Width — `SH`

`SH` **is** documented (`yaesu-cat-ft891.md:56`) as `SH0` + `nn` + `;`, a
width *index*, not a frequency.

| Question | Why it matters |
|---|---|
| The per-mode index → Hz table | **ANSWERED** (Hamlib, shared FT-891/991 table — now in `yaesu-cat-ft891.md`): CW/RTTY/DATA idx 1–17 (50–3000 Hz), SSB idx 1–21 (200–3200 Hz), AM/FM via `NA` only. FT-891 set format is `SH01nn;` (note the extra "on" digit) |
| Contiguous indices? | **ANSWERED**: yes, 1…N per mode; 0 = rig default |
| `NA` interaction | **ANSWERED** (ordering) / **BENCH** (reset behaviour): `NA` must be written *before* `SH`; ≤ narrow_max (500 CW / 1800 SSB) needs `NA01;`. Whether flipping `NA` alone re-clamps `SH` is a bench item |

Capture the table as data (a Swift dictionary keyed by mode), not as
scattered constants.

### 2.3 Manual notch — `BP`

| Question | Why it matters |
|---|---|
| Sub-address shape | **ANSWERED**: `BP00001;`/`BP00000;` on/off, `BP01nnn;` frequency |
| Units and range | **ANSWERED**: 10 Hz units, 001–320 → 10–3200 Hz |
| Step granularity | **ANSWERED**: 10 Hz (wire resolution) |
| Ordering vs enable | **BENCH**: Hamlib writes them independently; confirm freq-while-off is accepted |
| Read back | **ANSWERED**: `BP00;` and `BP01;` |

### 2.4 Contour — `CO`

| Question | Why it matters |
|---|---|
| Two-parameter shape | **ANSWERED**: `CO000001;`/`CO000000;` on/off (4-digit field), `CO01nnnn;` frequency |
| Range and units | **ANSWERED**: 10–3200 Hz, 1 Hz wire resolution |
| Level via menu? | **ANSWERED**: yes — level (−40…+20 dB) and width (1–11) are menu items already in the app's catalog; the handle has one CAT axis |
| CW applicability | **BENCH** (APF `CO02…;` exists for CW — a future CW-view feature, not strip v1) |

### 2.5 Auto notch — DNF

| Question | Why it matters |
|---|---|
| Reachable over CAT? | **ANSWERED**: yes — `BC00;`/`BC01;`, read `BC0;` |
| Mutually exclusive with manual notch? | **BENCH** — drives segmented-vs-toggles; default the UI to independent toggles and revisit |

### 2.6 Behavioural questions no manual will answer

- **Write cadence the radio tolerates.** A drag can emit 60 writes/second.
  Find the rate at which the FT-891 starts dropping or lagging, and set the
  coalescing interval below it. The CP2105 link runs at 38400 by default.
- **Read-back latency.** How long after a write does `IS;` report the new
  value? This sets how long optimistic UI must hold before reconciling.
- **Does changing mode reset shift/width/notch?** If it does, the strip must
  re-read on every mode change.

---

## 3. Model layer (`FT891Kit`)

Add typed wrappers next to the existing ones in
`Sources/FT891Kit/Commands/FT891Commands.swift`, which already establishes
the pattern (`qmxRead`-style helpers, `rawCommand` underneath).

```swift
public struct PassbandState: Equatable, Sendable {
    public var shiftHz: Int          // IS
    public var widthIndex: Int       // SH
    public var widthHz: Int          // resolved through the §2.2 table
    public var notch: NotchState     // BP: enabled + frequency
    public var contour: ContourState // CO
    public var mode: OperatingMode   // width tables are per-mode
}
```

Requirements on this layer:

- **One read call** that populates the whole struct, for use on appear and
  after a mode change.
- **Per-parameter write calls**, each idempotent, each clamped to the
  ranges found in §2.
- **A width table** keyed by mode, expressed as data.
- **No UI assumptions** — this layer returns Hz and indices; the strip
  decides how to draw them.

Everything here is testable against `FT891SimTransport` without a radio, and
should be: extend the simulator to model `IS`/`SH`/`BP`/`CO` state, including
rejecting out-of-range values the way the radio does.

---

## 4. The control (`FT891UI`)

`Sources/FT891UI/PassbandStrip.swift`, placed in the **bottom third** of the
Operate screen, ~80 pt tall, full width.

### 4.1 Layout

- X-axis: receive audio frequency, 0–3400 Hz, with ticks every 500 Hz.
- Passband: a filled capsule whose left/right edges are
  `centre ± width/2`, offset by shift.
- Notch: a marker at its frequency, dimmed when disabled.
- Contour: a low-profile handle on the same axis.
- Everything drawn in one `Canvas`; the axis never moves, so hit-testing is
  a simple x → Hz mapping.

### 4.2 Gestures

| Gesture | Target | Effect |
|---|---|---|
| Drag | passband body | shift |
| Drag | passband edge (±22 pt hit zone) | width, snapped to `SH` indices |
| Tap | empty strip | place notch, enable it |
| Drag | notch marker | notch frequency |
| Double-tap | notch marker | disable notch |
| Long-press | contour handle | contour on/off |

**Vertical distance scales sensitivity** while dragging, as Camera's exposure
control does: near the strip, 1 pt ≈ 1 step; 100 pt away, 1 pt ≈ 0.1 step.
This is what makes a 10 Hz notch adjustment possible on a 390 pt-wide screen.

### 4.3 Rules that keep it fast rather than fiddly

- **Snap with haptics.** `SH` is a small set of indices. Snap the edge to
  real widths and fire `sensoryFeedback(.selection)` on each change.
- **Coalesce writes** using the latest-wins pattern already in
  `RigController.tune(to:)` — a drag must never build a CAT backlog.
- **Optimistic UI**: draw immediately, reconcile on read-back, and ignore a
  read that arrives while a drag is still in flight.
- **Disable, don't fail**: if the mode doesn't support a control, grey it.

### 4.4 One-tap first

Auto-notch, if §2.5 says it is reachable, gets a **prominent button beside
the meter** — not a row in `RXControlsDrawer`. A steady carrier needs no
aiming, and the fastest possible fix should need no aiming either. The strip
is for what auto-notch cannot catch.

---

## 5. Accessibility

The strip is gesture-only, which the
[HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
does not accept on its own. Each element publishes an
`accessibilityAdjustableAction` so VoiceOver users can step shift, width and
notch frequency, with values spoken in Hz. Budget this as part of the
control, not as a follow-up.

---

## 6. Testing

| Layer | Test |
|---|---|
| Width table | every index maps to a bandwidth, per mode; no gaps |
| Wrappers | encode/decode round trip for every parameter; out-of-range values rejected before hitting the wire |
| Simulator | `IS`/`SH`/`BP`/`CO` state machine, including rejection behaviour |
| Strip geometry | x → Hz → x round trips at several widths; edge hit zones don't overlap the body zone |
| Coalescing | a synthetic 60 Hz drag produces ≤ N writes/second |

Geometry and coalescing are pure logic — keep them out of the view so they
can be tested without a UI host.

---

## 7. Definition of done

1. `yaesu-cat-ft891.md` documents `IS`, `SH` (with the per-mode table), `BP`,
   `CO` and DNF, each marked verified against hardware.
2. The simulator models all four, and the model layer's tests pass headless.
3. A drag across the strip on a real FT-891 reshapes the passband with no
   audible stepping and no command backlog.
4. Tapping the strip notches an audible carrier in one gesture.
5. VoiceOver can operate every parameter.

---

## 8. Implementation plan (2026-07-28)

With §2's formats researched, the work splits into five phases. Phases 1–4
run entirely against the simulator; phase 5 is the bench pass §1 demands
before the strip ships to a radio-connected build.

### Phase 1 — Simulator + wrappers (`FT891Kit`)

1. Extend `FT891SimRig` with passband state: `shiftHz`, `widthIndex` (+ the
   per-mode index tables), `naNarrow`, `notchOn/notchTens`, `contourOn/
   contourHz`, `autoNotchOn`. Model rejection exactly: out-of-range → `?;`,
   `IS`/`BP`/`CO` rejected in AM/FM, `SH` clamped by the mode table.
2. `Sources/FT891Kit/Passband/PassbandTables.swift`: the §2.2 width tables
   as data (`[FT891Mode: [Int]]` + `narrowMax`), with a total unit test
   (every index maps, no gaps, round-trip index↔Hz).
3. `Sources/FT891Kit/Commands/PassbandCommands.swift`: typed wrappers per
   the researched formats — `readPassband()` (one call populating
   `PassbandState` via `IS0;`/`SH0;`/`NA0;`/`BP00;`/`BP01;`/`CO00;`/
   `CO01;`/`BC0;`), and per-parameter writers that clamp, snap (`IS` to
   20 Hz pending bench, `BP` to 10 Hz), and order `NA` before `SH`.
4. Tests: encode/decode round trips for every parameter; rejection paths;
   `readPassband` against the sim.

### Phase 2 — Coalescing + geometry (pure logic, no UI)

1. `PassbandGeometry.swift`: x↔Hz mapping for a given strip width, edge
   hit-zones (±22 pt), vertical-distance sensitivity curve. Unit-test the
   round trips and that hit zones never overlap the body zone at the
   narrowest SSB width.
2. `PassbandWriteCoalescer`: latest-wins per parameter (the
   `tune(to:)` pattern generalised), with a configurable minimum interval
   (start 100 ms ≈ 10 writes/s — well under the 38400-baud budget; bench
   tunes it in phase 5). Test: a synthetic 60 Hz drag stream produces
   ≤ 1/interval writes and always ends on the final value.

### Phase 3 — RigController + state plumbing

1. `RigController` gains `passband: PassbandState?`, `refreshPassband()`
   (called on ready, on mode change, and after USB re-attach — §2.6's
   "does mode change reset it" is handled by always re-reading), and
   per-parameter setters that route through the coalescer and reconcile
   with a read-back **only after** the drag ends (optimistic during).
2. Mode-capability map: which controls exist per mode (no `SH` in AM/FM,
   contour SSB/CW only pending bench) — drives disabled states.

### Phase 4 — The strip (`FT891UI`) + accessibility

1. `PassbandStrip.swift` per §4: one `Canvas`, gestures per the §4.2
   table, snap haptics on `SH` index changes, greyed elements per the
   capability map. Auto-notch button beside the meter per §4.4
   (`BC01;`/`BC00;` behind `rig.setAutoNotch(_:)`).
2. Accessibility per §5: `accessibilityAdjustableAction` per element —
   shift steps 20 Hz, width steps one `SH` index (spoken in Hz), notch
   steps 10 Hz. This lands in the same PR as the gestures, not after.
3. Placement: bottom third of `OperateView`, above `RXControlsDrawer`;
   collapsed to a summary row when the mode supports nothing.

### Phase 5 — Bench verification (blocks release, not development)

On a real FT-891, in order: (1) one command of each format from §2's
ANSWERED rows — confirm echo/readback and mark the reference doc rows
verified; (2) the BENCH rows: `IS` CAT rounding, AM/FM rejection set,
freq-while-off notch, `NA`↔`SH` reset behaviour, DNF/MN exclusivity;
(3) §2.6 cadence: binary-search the write rate where the radio lags,
set the coalescer interval to half that; (4) §7's definition of done —
drag with no audible stepping, one-gesture notch of a real carrier.
Findings go into `yaesu-cat-ft891.md` the same day they're measured.

### Explicitly deferred

- APF (`CO02…;` + `EX1201n;` width) — a CW-view feature.
- Contour level/width editing from the strip (menu items; reachable
  through the existing Settings tab meanwhile).
- QMX: nothing here applies (read-only `FW`; no shift/notch/contour).
