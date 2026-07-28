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

**The order of work is: §2 first, on hardware, writing findings back into
`yaesu-cat-ft891.md`. Then §3 onwards.**

---

## 2. Unknowns to resolve on the bench

Each of these should end up as a row in the CAT reference doc, with the
answer and the date it was verified.

### 2.1 IF shift — `IS`

| Question | Why it matters |
|---|---|
| Exact wire format. Yaesu uses a sign and a fixed-width field; is it `IS0+nnnn;` / `IS0-nnnn;`, and is the leading `0` a fixed VFO selector? | Wrong width is a rejected command at best |
| Units and range — Hz, and what maximum? ±1000? ±1200? | Determines the strip's drag scale |
| Step granularity — does the radio round to 20 Hz, 50 Hz? | If it snaps, the UI must snap too or the readback will fight the drag |
| Does `IS;` read back the current value in the same format? | Needed for optimistic-UI reconciliation |
| Is shift mode-dependent (disabled in FM/AM)? | The strip must disable itself rather than send doomed writes |

### 2.2 Width — `SH`

`SH` **is** documented (`yaesu-cat-ft891.md:56`) as `SH0` + `nn` + `;`, a
width *index*, not a frequency.

| Question | Why it matters |
|---|---|
| The full index → bandwidth table, **per mode**. SSB, CW and DATA have different width lists on this radio. | The strip draws real Hz; it cannot without this table |
| How many indices per mode, and are they contiguous? | Snap points |
| Interaction with `NA` (narrow) — does `NA` reset or clamp `SH`? | Two controls fighting is a classic bug |

Capture the table as data (a Swift dictionary keyed by mode), not as
scattered constants.

### 2.3 Manual notch — `BP`

| Question | Why it matters |
|---|---|
| The two-parameter shape. Yaesu convention is `BP00nnn;` for on/off and `BP01nnn;` for the frequency — confirm which sub-address is which | The whole tap-to-notch interaction rests on this |
| Notch frequency units and range — Hz? tens of Hz? 10–3200? | Maps the tap's x-position to a value |
| Step granularity | Snap and haptics |
| Does enabling the notch require the manual-notch mode to be selected first (vs DNF)? | Ordering of the two writes |
| Does `BP` read back? | Reconciliation |

### 2.4 Contour — `CO`

| Question | Why it matters |
|---|---|
| Same two-parameter shape as `BP`? (`CO00nnn;` on/off, `CO01nnn;` frequency) | Reuse or diverge |
| Frequency range and units | Handle placement |
| Is contour level a menu item (`EX`) rather than CAT? | Decides whether the handle has one axis or two |
| Does contour apply in CW, or SSB only? | When to hide the handle |

### 2.5 Auto notch — DNF

| Question | Why it matters |
|---|---|
| Is DNF reachable over CAT at all, and under which command? | §4's one-tap button depends on it |
| Is it mutually exclusive with manual notch? | If so, the UI must present them as one segmented choice, not two toggles |

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
