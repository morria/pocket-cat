# Fun-Feature Backlog (post-v1)

Features the FT-891 CAT command set makes possible beyond the v1 scope in
[PLAN.md](../PLAN.md). Wire details in
[ft891-cat-commands.md](ft891-cat-commands.md). Ranked by differentiation —
the first four exist on no other iOS product.

## Tier 1 — differentiators

### 1. CW keyboard & macro pad
`KY` on the FT-891 **cannot send arbitrary text** (unlike FT-991) — it only
triggers playback of keyer memories 1–5. But `KM` loads up to 50 characters
into any memory over CAT, so type-to-transmit is a two-step:
`KM1<text>;` → `KY1;`. For long text, chunk ≤50 chars and sequence by
polling `TX;` (`TX2` = radio keying itself, `TX0` = done), loading the next
chunk into the alternate memory while the current one plays.

- Contest-style F1–F5 message buttons (persisted per profile).
- `KS` speed slider (4–60 WPM), `KP` pitch (300–1050 Hz), `BI` break-in,
  `SD` semi-BK delay, `CS` spot, `ZI;` one-tap zero-in.
- Requires CW MEMORY menu items 04-07…04-11 set to TEXT [COMMUNITY].
- Note: pocket-cat's `send(keyerText:)` emits FT-991-style `KY<text>;` —
  invalid on the FT-891; use the KM+KY dance (upstream note filed in plan).

### 2. SWR sweep (antenna analyzer)
Step the VFO across a range at low power (`PC005;`), key briefly, read
`RM6;` (SWR, raw 0–255) per step, plot the curve. Killer feature for
portable wire antennas. Safety framing is mandatory: explicit confirmation,
band-edge limits, duty-cycle caps, giant TX indicator, abort on Hi-SWR
(`RI0;`). Calibrate RM6 → SWR empirically (hamlib-style lookup).

### 3. Voice keyer (DVS)
`LM0n;` records mic audio into voice memories 1–5; `PB0n;` plays them on
air. Record CQ once, tap to call; auto-repeat timer = contest CQ machine.
`RI3;`/`RI4;` report REC/PLAY state. (Audio itself never crosses BLE — the
radio stores it.)

### 4. Memory-channel manager
`MR`/`MW` read/write channels 001–099 + PMS pairs with the full field
record; `MT` adds the 12-char alpha tag (pad to exactly 12). Phone-based
editor: reorder, import/export, share sheets — replaces ADMS-891. Slots
into the profile schema's reserved `memories` key. `QI;`/`QR;` quick-memory
store/recall as a bonus button.

## Tier 2 — strong additions

### 5. Band activity scan
RX-only VFO stepping + `SM0;` per step → band activity strip; or drive the
radio's scanner (`SC1;`/`SC2;`, stop `SC0;`) with `BY;` squelch-busy to
stop on activity.

### 6. Remote power switch
The USB UART stays powered when the rig is off. Manual-documented quirk:
send dummy bytes, wait >1 s and <2 s, then `PS1;`. `PS0;` for off.

### 7. FM/repeater helper card
One tap sets tone mode `CT0p;`, tone/DCS `CN0pnnn;` (full 50-tone CTCSS +
104-code DCS index tables are in the CAT doc), repeater shift `OS`, and
`QS;` quick-split.

### 8. Split/DX helper
"Work him 5 up": `AB;` copy A→B, nudge B, `ST1;` split on, `TS1;` TXW to
listen on the TX freq, `OI;` opposite-band readout.

## Tier 3 — nice touches

### 9. Shack-integration details
- `RI0;` Hi-SWR flag → warning banner; `RIA;`/`RIB;` mirror TX/RX LEDs.
- `MS` front-panel TX meter select synced with the in-app meter picker.
- `DA` dimmer: sync radio backlight to phone dark mode / "night ops".
- `LK1;` lock the physical panel while remote-controlling.
- `UL;` PLL unlock indicator (diagnostics screen).

### 10. RIT scrub wheel
`CF` on/off + `RD`/`RU` nudges + `RC;` clear — a small inertial wheel with
haptic detents beside the main dial.

### 11. CW beacon mode
KEYER menu group has beacon interval items — configure a keyer memory +
interval over EX and the radio beacons autonomously; the app is just the
configurator with a countdown display.

### 12. App-level (not CAT) ideas
Auto-log on QSY/mode change with ADIF export; POTA/SOTA spot integration
(tune to a spot in one tap); time-on-frequency history scrubber.
