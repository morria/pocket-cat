# Rig Control UX — Design Pass

**Status:** §4.1–4.3 built in both apps (band bar with stacking, memories,
recents); §3 and §4.4 still proposals, blocked on CAT formats this repo
does not yet document · **Scope:** `ios/pocket-cat-ft891` and
`ios/pocket-cat-qmx`

Three questions drive this: how to kill an unwanted whistle in one gesture,
how to hop around the band without thinking, and what iOS-native prior art
should shape both.

## 1. Where the interface stands today

| App | Receive controls | Band/frequency |
|---|---|---|
| FT-891 | `RXControlsDrawer` — a collapsed `DisclosureGroup` with AF/RF/squelch sliders and NB/NR/ATT/AMP toggles | digit-drag tuning, direct entry |
| QMX | AGC and filters only via the menu tree | digit-drag tuning, direct entry |

Two problems, both structural rather than cosmetic:

**Everything interesting is behind a disclosure triangle.** The controls you
reach for when a signal is unreadable are the ones that take the most taps to
find. A drawer is the right home for AF gain, which you set once; it is the
wrong home for a notch, which you reach for *because something is wrong right
now*.

**Nothing is spatial.** Shift, width, notch and contour all describe positions
and shapes in one frequency window, and four independent sliders throw that
relationship away. The operator has to hold the passband picture in their head
and translate it into four numbers.

### 1.1 What each radio can actually do

This is where the two apps stop being symmetric, and the design has to be
honest about it.

**FT-891** — the full Yaesu receive chain: IF shift (`IS`), width (`SH`),
manual notch (`BP`), contour (`CO`), auto-notch (DNF), NB, NR. The repo's CAT
reference (`esp32s3/docs/references/yaesu-cat-ft891.md:78`) is an explicit
subset and treats the rest as available — **the exact `BP`/`CO`/`IS` field
formats must be confirmed against the FT-891 CAT manual before any of this is
built.**

**QMX** — has no IF shift, no manual notch, and no contour. `FW` is
**read-only** (`qmx-cat.md:48`); filter selection lives in the `MM` menu tree.
So the passband editor below is an FT-891 feature. The QMX's answer to a
whistle is RIT, AGC threshold, a filter preset — and, once
[`docs/qmx-panadapter.md`](qmx-panadapter.md) lands, *seeing* the carrier.

Pretending otherwise would produce a QMX screen full of controls that do
nothing.

## 2. Prior art

### 2.1 What the leading iOS rig-control app does

[SDR-Control](https://documents.roskosch.de/sdr-control-ipad/) (Marcus
Roskosch) is the most mature iOS transceiver controller, in iPad and
[Mobile](https://documents.roskosch.de/sdr-control-mobile/) editions.

| Behaviour | Detail | Worth taking? |
|---|---|---|
| Double-tap the waterfall to QSY | "Double-tap somewhere on the waterfall to move the currently active VFO to that frequency" | **Yes** — the cheapest possible tune gesture |
| Drag the VFO line | "tap-and-hold the VFO Frequency (the yellow line) and move it left or right" | **Yes** — direct manipulation of the thing itself |
| Memories: tap to tune | "You can single tap to tune to a certain memory" | **Yes** — matches list-selection convention |
| Memories: `+` stores current | "the current frequency and mode settings can be stored using a desired memory name" | **Yes** |
| Filters behind a `FIL` button | "Tapping on the FIL button, you can select Filter 1 to 3" | **No** — presets, not a passband |
| Scrollable button bar | how the iPhone edition fits its controls | **No** — a wall of buttons is what we're avoiding |
| **No waterfall on iPhone** | "optimized for the small iPhone screen… use the iPad version… which offers additional features like displaying a Waterfall" | Instructive — see below |

**The most useful finding is a negative one.** Neither manual documents any
touch gesture for passband, shift, or notch adjustment. The leading app in
this category has not solved the problem this design is about, so there is
room to do it properly — and no established convention to violate.

Their iPhone edition dropping the waterfall entirely is a warning worth
heeding: a spectrum display that is too small to touch accurately is worse
than none. Our panadapter plan should treat the iPhone as the *primary*
target and design the touch targets first, not shrink an iPad layout.

### 2.2 Apple's own interfaces, which are better prior art than ham software

The passband problem — position, width, and a notch inside one frequency
window — is the same shape as a parametric EQ, and Apple has shipped that
touch interface repeatedly:

- **Logic Pro for iPad / GarageBand EQ** — draggable nodes on a frequency
  curve; horizontal drag moves frequency, vertical drag moves gain, pinch
  changes Q. One canvas, three parameters, no sliders.
- **Camera** — tap to set focus, then a *vertical drag from the tap point*
  fine-tunes exposure. The pattern is "tap to place, drag to refine", which is
  exactly the notch interaction.
- **Photos adjustments** — a horizontal scrubber with haptic detents for
  values that need precision without a keyboard.
- **Podcasts/Music/Mail rows** — swipe actions, tap to activate, drag to
  reorder. The memory list should look like every other iOS list.
- **Phone → Recents, Safari history** — automatic history beats manual
  bookmarking for revisiting.
- **Home app** — oversized tap targets for the controls you use in a hurry.

Relevant [HIG](https://developer.apple.com/design/human-interface-guidelines)
principles applied below: [sliders](https://developer.apple.com/design/human-interface-guidelines/sliders)
suit values where precision is not critical (so: not a notch);
[gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)
must not fight system edge swipes; and
[accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
requires that anything gesture-only also be reachable another way.

## 3. Proposal — the passband strip (FT-891)

One control replaces four sliders: a horizontal strip, full width, ~80 pt
tall, living in the **bottom third of the screen** where a thumb reaches. Its
x-axis is receive audio frequency, roughly 0–3400 Hz, drawn once with tick
labels.

```
   0        500       1000      1500      2000      2500     3000 Hz
   ├─────────┬─────────┬─────────┬─────────┬─────────┬─────────┤
             ▐███████████████████████████████▌                     ← passband
                  ▼                                                ← notch
             ╰─ drag edge          drag body ─╯
```

| Gesture | Effect | CAT |
|---|---|---|
| Drag the passband **body** | IF shift | `IS` |
| Drag either **edge** | width, snapping to the radio's real filter steps | `SH` |
| **Tap** empty strip | place the notch there and enable it | `BP` |
| Drag the **notch marker** | sweep the notch | `BP` |
| Vertical distance while dragging | fine/coarse sensitivity, Camera-style | — |
| **Double-tap** the notch | remove it | `BP` off |
| Long-press the **contour** handle | contour on/off | `CO` |

Details that make it fast rather than fiddly:

- **Snap with haptics.** `SH` is a small set of indices, not a continuum. Snap
  to real widths and fire `sensoryFeedback(.selection)` at each — the strip
  should feel like detents, not like a smear.
- **Coalesce writes.** Reuse the latest-wins pattern already in
  `RigController.tune(to:)` so a drag never builds a backlog of CAT frames.
- **Optimistic UI.** Move the drawing immediately, reconcile on read-back.
- **VoiceOver.** The strip publishes `accessibilityAdjustableAction` for each
  element so it is not gesture-only.

### 3.1 The actual fastest whistle-killer

A steady carrier does not need any of the above: it needs **one tap on DNF**.
Auto-notch is currently buried with everything else, and it should be a
first-class button beside the meter, not a row in a drawer. The manual strip
is for what auto-notch cannot catch.

So the hierarchy is: **DNF button** (one tap, no aiming) → **tap the strip**
(one tap, rough aim) → **drag the notch** (precise) → **shift/width** (reshape
around it).

### 3.2 On the QMX, tap the whistle itself

Once the panadapter is live, the carrier is *visible*, and the fastest
interaction becomes the most obvious one: **tap the spike on the spectrum**.
The tap lands on a frequency, and that frequency is the notch. Drag the shaded
receive window's edges to set width the same way.

This is the strongest argument for the panadapter beyond eye candy — it turns
"hunt for the whistle by ear" into "point at it". Marking the notch position
on the spectrum also gives visual confirmation the notch is where you think.

## 4. Proposal — band hopping

### 4.1 The band bar earns its screen space

A horizontally scrollable row of band chips (160 · 80 · 60 · 40 · 30 · 20 ·
17 · 15 · 12 · 10 · 6), pinned above the passband strip.

- **Tap** → QSY to the **last frequency you used on that band**, restoring
  mode and filter with it. This is band-stacking, exactly as a modern rig
  does it, and it is the single highest-value change in this document.
- **Long-press** → menu: *Save current here*, *CW segment*, *Digital segment*,
  *SSB segment*, *Band edges*.
- Chips show the current band highlighted.

All of it is device-side state, so it works identically on both radios and
needs no radio memory support at all.

### 4.2 Memories, as an ordinary iOS list

A `Memories` sheet, deliberately conventional (§2.2):

- Rows: name, frequency, mode, band — grouped in sections by band.
- **Single tap tunes** and dismisses, matching SDR-Control.
- **Swipe** for rename/delete; **drag** to reorder; **`+`** stores the current
  VFO with a suggested name.
- Search field once the list is long.
- Stored as JSON on device, synced through the same iCloud container the
  Profiles feature already uses — so this rides existing infrastructure.

### 4.3 Recents, which cost the operator nothing

Every frequency held for more than ~10 seconds gets recorded, deduped, and
offered as the last ten in a menu on the frequency display. No decision to
save, no naming — the Phone-app Recents model. In practice this is what people
actually want when they chase a spot and then want their old frequency back.

### 4.4 QMB, only where it's real

For the FT-891, mirroring the radio's own quick memories keeps the app and the
front panel in agreement — a tap to recall and a long-press to store, on a
single QMB control. This depends on Yaesu's `MW`/`MC` (and whatever the FT-891
uses for quick memory) behaving as documented; the repo's CAT reference does
not cover them, so **confirm against the manual before building.**

The QMX has no equivalent, and §4.1–4.3 give it the same capability without
one. If QMB turns out to be awkward on the FT-891, nothing is lost by
shipping only the device-side features.

## 5. Smaller things that add up

- **Thumb zone.** PTT, band bar and passband strip belong in the bottom third;
  the frequency readout and meters can live up top where they are read, not
  touched.
- **Haptics** on band change, notch placement, and filter detents.
- **Live Activity** showing frequency, mode and TX state on the Lock Screen.
- **Landscape on iPhone** for the panadapter, since width is what a spectrum
  needs.
- **Keep the transmit border.** The FT-891 app's full-screen red border while
  transmitting is exactly right and should appear in the QMX app too.

## 6. Suggested order

| # | Change | Why first |
|---|---|---|
| 1 | Band bar with band-stacking | Biggest win per hour of work; both apps; no CAT unknowns |
| 2 | DNF promoted out of the drawer | One line of layout, removes the most common frustration |
| 3 | Memories sheet + Recents | Conventional iOS, rides existing iCloud plumbing |
| 4 | Passband strip (FT-891) | The novel piece; needs `IS`/`SH`/`BP`/`CO` formats confirmed first |
| 5 | Tap-to-notch on the panadapter (QMX) | Blocked on the panadapter |
| 6 | QMB mirroring (FT-891) | Only if the CAT surface cooperates |

Items 1–3 need no new CAT knowledge and can ship immediately. Item 4 is the
one that needs a manual and a radio on the bench.
