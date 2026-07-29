# QMX Panadapter — Implementation Plan

**Status:** proposed, nothing built · **Scope:** QMX only
**Supersedes:** the "waterfall/spectrum" v1 non-goal in
[`docs/ios-implementation.md`](ios-implementation.md) §1 — this is the v2 plan
for that feature.

## 1. Purpose

Put a live spectrum display and waterfall on the phone, fed by the QMX's raw
I/Q stream, over the existing BLE bridge.

Only the QMX can source this. It presents a composite USB device — CDC-ACM for
CAT **plus a USB sound card** — and the `Q9` CAT command switches that sound
card from demodulated audio to raw I/Q
(`esp32s3/docs/references/qmx-cat.md:15,105`;
`ios/pocket-cat-qmx/Sources/QMXKit/Menu/QMXMenuNotes.swift:96`). The FT-891 and
FTX-1 have no equivalent, so this feature is radio-specific by nature and stays
behind a capability probe.

### 1.1 What this does to the dumb-pipe principle

The system design fixes the bridge as a transparent byte pipe with all radio
knowledge in Swift (`esp32s3/docs/implementation.md` §1). DSP in firmware bends
that, so the split is drawn deliberately:

| Firmware owns | Because |
|---|---|
| USB audio transport, FFT, dB conversion, bin decimation | Sample-rate arithmetic, not radio semantics. Identical for any I/Q source. |
| Nothing about frequency, band, mode, or calibration | It doesn't know them, and must not learn them. |
| iOS owns | |
| Centre frequency, axis labels, span/zoom, dB calibration offset | The app already polls the VFO; the bridge would have to parse CAT to know it. |

Concretely: **spectrum frames carry no centre frequency.** They carry a sample
rate and bins of dBFS. The app labels the axis from the VFO frequency it
already tracks. That keeps the firmware ignorant of CAT, and means a future
I/Q source on another radio reuses the whole path unchanged.

## 2. Budget

At 48 kHz stereo 16-bit, raw I/Q is 1.54 Mbps — about 10× what BLE can
carry, so the decimation is not optional. **Expect 24-bit, not 16**: the
QMX's sound card streams 24-bit samples (it needs the dynamic range for
I/Q; QRP Labs documents 48 ksps 24-bit). That is 2.3 Mbps raw — still
trivial on USB, irrelevant to BLE (bins are 8-bit regardless), but the
DSP front end must ingest 3-byte packed samples from day one. Treat
16-bit as the *surprise* case, not the plan. Measured against a
conservative 100–300 kbps sustained notification budget (**to be verified on
hardware, not assumed**):

| Payload | Rate | Verdict |
|---|---|---|
| Raw 48 kHz I/Q | 1540 kbps | Impossible |
| I/Q decimated to 8 kHz complex | 256 kbps | Over budget, starves CAT |
| **256 bins × 8-bit @ 15 fps** | **~31 kbps** | **The design point** |
| 512 bins @ 20 fps | ~82 kbps | Upper end, needs measurement |

USB ingress is not a constraint: 1.54 Mbps fits full-speed 12 Mbps with room
to spare. Neither is CPU — a windowed 512-point complex FFT at 15 fps is a few
percent of one 240 MHz LX7 core with `esp-dsp`, against the ~90 FFTs/s the
sample rate would allow.

## 3. Protocol changes (normative — land in `esp32s3/docs/protocol.md`)

### 3.1 New characteristic

Base UUID `8f1dXXXX-52a4-4e1e-b34b-9d40b71d6e01`; `0001`–`0005` are taken
(protocol.md §1).

| XXXX | Name | Properties | Direction | Payload |
|---|---|---|---|---|
| `0006` | `SPECTRUM` | Notify | device → central | fragmented spectrum frames (§3.3) |

### 3.2 New CTRL opcode

| Op | Name | Payload | Errors |
|---|---|---|---|
| `0x07` | `SET_SPECTRUM` | `[enable:u8][bins:u16][fps:u8]` | `BAD_LEN`, `BAD_ARG`, `NO_USB`, `UNSUPPORTED`, `BUSY` |

- `enable = 0` stops streaming; remaining fields ignored.
- `bins` ∈ {64, 128, 256, 512}; `fps` ∈ 1–30. Anything else → `BAD_ARG`.
- `enable = 1` while already streaming is a **reconfigure**, ACKed, never
  `BUSY` — so the app can change bins/fps in one call without a
  stop/start glitch. (`BUSY` is reserved for a transient internal state,
  e.g. mid USB attach; the app treats it as retryable.)
- The firmware validates *achievability at the live ATT MTU* before
  ACKing: fragments per frame × fps must fit its notify budget. A 23-byte
  MTU asking for 512 bins @ 30 fps is `BAD_ARG`, not a silent stall —
  §3.3's "any MTU ≥ 32" is a statement about frame-format correctness,
  not throughput, and bench clients at default MTU would otherwise see a
  permanently blank waterfall.
- Streaming **auto-stops** on BLE disconnect and on USB detach. It is never
  persisted; a reconnecting central starts quiet.
- The `SPECTRUM` characteristic is notify-gated on subscription (the
  `status_subscribed` pattern in `ble_link.c`): no subscriber, no work.

**Capability discovery costs nothing new.** Firmware without the DSP path
answers `NAK` with `CTRL_ERR_UNSUPPORTED` — already defined at
`ctrl_proto.h:42` and currently unused. So the app probes by asking, and the
22-byte `STATUS` layout (protocol.md §3) does not change. No format-version
bump, no golden-vector churn on the existing status path. **The probe must
also treat `CTRL_ERR_UNKNOWN_OP` as "absent"** — that is what every
*currently shipped* firmware answers for opcode `0x07`, and it is the
answer the probe will actually meet in the field for the next year.

### 3.3 Frame format

Little-endian, consistent with §2. Fragment 0 carries the header; continuation
fragments carry only enough to place their bins.

```
frag 0 : [seq:u8][frag:u8=0][nfrags:u8][flags:u8][first_bin:u16]
         [bins_total:u16][sample_rate_hz:u32][bin bytes…]   header = 12 B
frag n : [seq:u8][frag:u8][nfrags:u8][first_bin:u16][bin bytes…]
                                                            header =  5 B
```

- `flags` is reserved (0 in v1) — one byte buys format evolution
  (averaged/peak-hold traces, 16-bit bins) without a new characteristic.
  Non-zero flags the decoder doesn't know → drop the frame, don't guess.
- Bins are **dBFS at 0.5 dB/LSB**: `0` = full scale, `255` = −127.5 dBFS.
  128 dB of range, more than the radio has. The dB reference is defined
  against a full-scale sine *after* the specified window (Hann) and FFT
  normalisation — pin this in the golden vectors or the synthetic-source
  tests will silently bake in whatever the first implementation did.
- Bin 0 is the lowest frequency of the window; **bin `bins_total/2` is DC**
  (even split: one extra bin below centre than above). Span is
  `sample_rate_hz`.
- **DC handling is mandatory, not cosmetic.** Direct-conversion I/Q has a
  DC offset that renders as a permanent fake carrier on the tuned
  frequency — the classic panadapter bug. The firmware subtracts the
  block mean before the FFT; the app may additionally interpolate the
  centre bin for display. Likewise assume **spectral inversion is
  possible** (I/Q swapped somewhere in the chain): verify against a known
  off-centre signal at M5 and, if mirrored, flip in `QMXKit` — never in
  firmware, which cannot know.
- `seq` is assigned **when a frame is generated, not when transmitted**,
  increments per frame, and wraps. Dropped frames therefore appear to the
  central as sequence gaps — that is the drop-reporting mechanism (§3.4).
- Frames are transmitted **atomically**: all fragments of a frame are
  handed to the stack back-to-back, and if any fragment's notify fails
  the remaining fragments are abandoned (the partial frame dies on the
  air). The central drops any incomplete frame; a `frag 0` bearing a new
  `seq` always resets reassembly, discarding whatever was pending.

At ATT_MTU 185, 256 bins is 2 fragments; at the negotiated 247 (the
firmware's `ATT_PREFERRED_MTU`) it is also 2. The *format* tolerates any
MTU ≥ 32; achievability at small MTUs is enforced at `SET_SPECTRUM`
(§3.2).

### 3.4 A deliberate exception to the data-path guarantees

protocol.md §4 currently states: *"BLE notify backpressure never drops (§5.1) —
bytes are retried."* **Spectrum inverts this.** The frame queue is depth 1–2
and drops the newest frame when full; frames are never retried and never
queued behind CAT.

This is a safety property, not an optimisation. The dead-man failsafe drops PTT
when the link goes quiet (protocol.md §2, failsafe semantics). A spectrum
backlog that delayed CAT or CTRL traffic could trip the failsafe mid-
transmission, or mask a real link loss. CAT always wins; a stale waterfall row
is worthless anyway.

**Dropped frames are reported by the `seq` gap alone — do NOT reuse
`EVT_OVERFLOW`.** An earlier draft proposed `EVT_OVERFLOW` with
`which = 2`; that is a live-fire bug against the shipped decoder:
`CtrlProtocol.swift:139` decodes *any* non-zero direction byte as
`.bleToUSB`, and the session's `handleOverflow` responds by resetting the
CAT demux and **failing the in-flight CAT command**
(`TransceiverSession.swift`, overflow path). Spectrum drops are routine
by design, so reusing the event would convert normal operation into a
stream of spurious CAT failures and user-facing "bridge dropped bytes"
notices. Sequence gaps carry the same information for free, per-frame,
with no rate limit and no cross-version hazard.

## 4. Firmware design

Two new components, following the repo's existing pure-vs-glue split
(`ctrl_proto` and `cat_bridge` are pure C and host-tested; `usb_link` is glue):

```
components/
  spectrum/      pure C: window → FFT → magnitude → dB → bin decimate →
                 fragment into frames.  No ESP-IDF dependency, host-tested.
  usb_audio/     glue: UAC host driver, isochronous IN, feeds spectrum/
```

- `spectrum` exposes a source-agnostic entry point taking a block of interleaved
  I/Q samples. `esp-dsp` supplies `dsps_fft2r` and the log table.
- `ble_link` gains the `0006` characteristic and the drop-newest queue.
- `ctrl_proto` gains `CTRL_OP_SET_SPECTRUM` and its validation.

**Build the synthetic source first.** A sweep/noise generator behind the same
interface as the real one lets the entire transport — protocol, firmware, Swift
decoder, UI — be built and tested with no radio attached, and gives CI
something deterministic to run. The real USB path then replaces the stub
without touching anything downstream.

## 5. The I/Q source (the unproven half)

### 5.1 Blocker: config descriptor size

`esp32s3/firmware/sdkconfig:2357` has `CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE
= 256` (the IDF default, not overridden in `sdkconfig.defaults`). ESP-IDF
rejects any device whose **entire config descriptor** exceeds it
(`components/usb/enum.c:552-557`). A CDC-ACM + UAC1 composite — audio control,
two streaming interfaces with alt settings, format-type and AS-general class
descriptors — routinely lands at 250–400 bytes.

If the QMX crosses it, enumeration fails **before `on_new_device` runs**, so
`radio_detect` never executes and the app sees nothing at all — not even
`RADIO_UNSUPPORTED`. Raise it to 512–1024.

This is a one-line change that gates everything, **and it is not specific to
this feature**: if the QMX's sound card is present unconditionally, plain CAT
bring-up hits the same wall. Do it first regardless.

### 5.2 Coexistence with CDC

Should work, needs proving. The CDC driver claims only its two interfaces
(`cdc_acm_host.c:200,215`) and never issues `SET_INTERFACE` on the streaming
ones, so their alt≠0 isochronous endpoints are free for a UAC driver to claim.
The DWC host controller supports isochronous pipes (`hcd_dwc.c:1717`).
Espressif maintains a `usb_host_uac` component; version compatibility with the
pinned IDF (v5.3) is unverified.

**Confirmed gotcha (external):** UAC and CDC-ACM co-existing on one host
needs the UAC component's **`create_background_task = true`** — without it the
two functions fight over the host. Source: `SteffenLav/qmx-panadapter` (they
also patched the UAC component and pin ESP-IDF 5.4.4; we're on 5.3.5, so
budget time for a component bump or backport at M4). Their I/Q is **48 kHz
stereo**, matching §2. They also run a **Gram-Schmidt orthogonaliser** to
correct I/Q amplitude/quadrature imbalance — without it, ~30 dB mirror images
appear on the waterfall. Our firmware DSP does DC removal (§3.3) but no
imbalance correction; add it at M4 for image rejection, or accept mirrors in
v1. Their client retries the `Q9` handshake up to 4× at connect — `QMXKit`
now does the same (`QMXSpectrum.iqModeAttempts`).

Interface selection already handles compositeness correctly and is unit-tested
with a QMX-shaped fixture — audio on 0/1/2, CDC comm on 3, data on 4, asserting
`cat_iface == 3` (`esp32s3/test/host/test_radio_detect.c:53-69`).

### 5.3 Enabling I/Q, and its cost to the user

`Q9` is session-only and not saved to EEPROM (`qmx-cat.md:105-106`), so the app
must re-issue it after every radio power cycle, and on reconnect if the radio
may have been cycled.

**The tradeoff is real but narrower than it looks.** `Q9` streams I/Q
*instead of* demodulated audio on the same sound card. In the Pocket Cat
system, however, **nothing consumes that audio today** — the bridge does
not claim the UAC interfaces, and there is no host computer in the loop —
so flipping `Q9` costs the current user nothing. It matters in two future
cases: phone-side audio decoding (§10 non-goal) becomes impossible while
the panadapter runs, and a QMX later replugged into a PC mid-session
would hand WSJT-X I/Q instead of audio (self-healing on power cycle,
since `Q9` is session-only). Disclose the mode in the UI for honesty,
but don't architect around a conflict that doesn't exist yet.

Two operational details the app must own:

- **Re-issue and verify.** Reassert `Q9` on session ready and on every
  `usbRadioAttached` event (a radio power cycle drops USB, and the
  setting died with it) — and read `Q9;` back rather than assuming.
- **Transmit blanks the stream.** During PTT the RX chain's I/Q is not
  meaningful; the waterfall should visibly pause/grey during TX rather
  than paint junk rows into history.

## 6. iOS design

**Spectrum data must ride the `BridgeTransport` seam, not bypass it.**
The tempting shortcut — `CATBridgeBLE` publishing an
`AsyncStream<SpectrumFrame>` directly off the characteristic — cuts every
simulator out of the loop: `QMXSimTransport`, `FT891SimTransport`, and
the scripted test transports implement `BridgeTransport`, and anything
that doesn't flow through it cannot be faked, which forfeits the repo's
entire no-hardware test strategy (and M3). Instead: `TransportEvent`
gains a `.spectrumData(Data)` case (raw fragments), the **session** owns
reassembly and exposes `spectrumFrames() -> AsyncStream<SpectrumFrame>`
plus `setSpectrum(bins:fps:)`/`stopSpectrum()` beside its other typed
APIs. Thirty events/s through the session actor is noise next to its
per-command traffic. This also keeps the single-consumer `events` model
intact instead of inventing a second delivery path.

| Layer | Addition |
|---|---|
| `CATBridgeCore/Spectrum/` | `SpectrumFrame` + reassembly: fragment ordering, sequence gaps, flags check, drop-on-incomplete. Pure, headless-testable, **no CoreBluetooth** (ios-implementation.md §3). |
| `CATBridgeCore/Session` | `.spectrumData` transport event; `spectrumFrames()` stream; `setSpectrum`/`stopSpectrum` (CTRL); auto-`stopSpectrum` on `scenePhase` background is the app's job, but the session stops on disconnect for free. |
| `CATBridgeBLE` | Subscribe `0006`; forward fragments as `.spectrumData`. `BridgeGATT.swift` gains the UUID. |
| `CATBridgeCore/Ctrl` | `SET_SPECTRUM` encode + `UNSUPPORTED`/`UNKNOWN_OP` probe handling in `CtrlProtocol.swift`. |
| `QMXKit` | Panadapter policy: issue + verify `Q9`, re-issue on USB re-attach, map VFO frequency onto the axis, own the calibration offset and any spectral flip. `QMXSimTransport` gains a synthetic sweep source so previews/tests render with no hardware. |
| `QMXUI` | Trace view + waterfall; TX blanking; stop streaming when backgrounded (waterfalls in the background only burn the bridge's 500 mAh cell). |

Rendering: SwiftUI `Canvas` is adequate for a 256-bin trace at 15 fps. For a
scrolling waterfall with history, use a Metal texture and shift rows rather
than redrawing — the standard approach, and far cheaper.

Frequency labelling is the app's job (§1.1): it holds the VFO frequency, so
the axis is `vfo ± sample_rate/2`, adjusted for the offset the QMX applies in
I/Q mode. **RESOLVED (external): the QMX presents I/Q at +12 kHz IF** — the
stream's DC bin (frame centre) is `vfo + 12 kHz`, so the tuned signal sits a
quarter-span below centre. Source: the `SteffenLav/qmx-panadapter` project
(M5Stack Tab5 / ESP32-P4), which shifts bin selection by `n_bins/4` for the
same reason. Modelled in `QMXKit`'s `QMXSpectrum` (offset constant + bin↔Hz
mapping, unit-tested); the axis labels and VFO marker already use it. Confirm
the exact value against a real radio at M4. **Visually re-centring the trace
on the VFO** (vs marking it in place, which v1 does) is a real DSP/display
decision — the QMX baseband is asymmetric about the VFO (`vfo−12k…vfo+36k`),
so centring means cropping or panning; make that call against real I/Q at M4,
per the reference's `n_bins/4` crop.

Three labelling edge cases that will otherwise ship as bugs:

- **Retuning smears history.** Waterfall rows were captured at the old
  VFO; on QSY the app must either shift history horizontally by Δf (nice)
  or clear it (honest). Doing neither paints signals at frequencies they
  were never on — users notice immediately, especially while dragging the
  dial through a band.
- **RIT and split**: the axis should track the *receive* frequency
  (VFO ± RIT; VFO A vs B per `FR`), not blindly `FA`.
- **Display quality**: a single 512-point FFT per frame is visually
  noisy. Averaging 2–4 FFTs per emitted frame costs a rounding error of
  CPU (§2 headroom) and transforms the trace; make it the synthetic
  source's default so golden expectations include it.

## 7. Testing

Mirrors the existing strategy (`esp32s3/docs/implementation.md` §7):

- **Host C** (`test/host/test_spectrum.c`): windowing, FFT, dB conversion and
  bin decimation against golden arrays; fragmentation of every bin count at
  MTU boundaries; `SET_SPECTRUM` validation in `test_ctrl_proto.c` style.
- **Golden vectors**: add spectrum frames to `test/vectors/ctrlproto.json` and
  the Swift copy in `Tests/CATBridgeCoreTests/Resources/` in the same commit —
  CI byte-compares them, so they cannot drift.
- **Python** (`test/tools/`): `catproto.py` decodes the new frames;
  `ble_client.py` gains a `spectrum` subcommand for bench use.
- **Swift**: reassembly against gaps, duplicates, truncation, MTU changes.
- **HIL, the acceptance test that matters**: `soak.py` runs CAT polling *and*
  spectrum concurrently, asserting **CAT round-trip latency does not regress**,
  that frames drop (not queue) under induced backpressure, and — explicitly —
  that **the failsafe never trips** during a sustained spectrum + keyed-TX
  soak. That last assertion is the safety property §3.4 exists for; test it
  by name, not by implication.

## 8. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M0 | Raise `CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE`; confirm a QMX with its sound card active enumerates and CAT works | `EVT_USB` reports `QMX_CDC`; `ID;` round-trips on hardware |
| M1 | Protocol spec §3 changes; `ctrl_proto` opcode + host tests + vectors both sides | C and Python suites green; CI vector compare passes |
| M2 | `spectrum` component with synthetic source; `ble_link` characteristic and drop-newest queue | Host tests green; `ble_client.py spectrum` shows a moving sweep |
| M3 | Swift decoder + `AsyncStream`; QMXUI trace and waterfall against the synthetic source | Waterfall renders at 15 fps on device with no radio attached |
| M4 | `usb_audio`: UAC host claiming the streaming interfaces alongside CDC | Isochronous IN delivers samples while CAT stays up |
| M5 | `Q9` wiring in QMXKit, axis calibration, UI disclosure of the audio tradeoff | Real signals appear at the right frequencies on hardware |
| M6 | Measurement pass | Sustained fps and CAT latency under load recorded; battery life on the 500 mAh cell measured |

M1–M3 need no radio and no USB work. M4 onward is where the unknowns live.

## 9. Risks and open questions

| Risk | Impact | Mitigation |
|---|---|---|
| QMX config descriptor > 256 B | Total enumeration failure, silent | M0, before anything else — and the raise lands in `sdkconfig.defaults` (the checked-in source of truth), not the generated `sdkconfig` |
| 24-bit samples assumed late | DSP front-end rework | §2: plan for 3-byte packed from day one |
| DC spike / spectral inversion | Fake carrier at VFO; mirrored display | §3.3: mean-subtract in firmware; flip check at M5 in QMXKit |
| Small-MTU client requests unachievable bins×fps | Silent blank waterfall on bench tools | §3.2: `SET_SPECTRUM` validates against live MTU |
| Panadapter halves bridge battery | User surprise | §6 background auto-stop; publish the measured runtime in M6, in the README, next to the 500 mAh figure |
| `usb_host_uac` incompatible with IDF 5.3 or with a concurrent CDC claim | Kills the source; transport still usable with a stub | Prove in M4; the stub keeps M1–M3 shippable |
| QMX descriptor declares an unexpected rate/format | Rework of the DSP front end | Read the real descriptor early in M0 |
| iOS notify throughput below budget | Fewer bins or lower fps | `fps`/`bins` are runtime parameters; measure in M6 |
| Spectrum traffic delays CAT or trips the failsafe | Safety | Drop-newest, depth-1 queue, CAT priority; asserted in the HIL test |
| Continuous isochronous + DSP + BLE on a 500 mAh cell | Short battery life | Measure in M6; streaming is opt-in and auto-stops |
| I/Q not centred on the VFO | Mislabelled axis | Determine on hardware in M5 |
| Multiple CDC functions on the QMX ("COM port**s**", `QMXMenuNotes.swift:102`) | Wrong CAT interface chosen | Confirm at M0; `find_cdc_acm_comm` takes the lowest-numbered with no tie-break |

## 10. Non-goals

- **TX audio** phone → bridge → radio. The QMX accepts USB audio for SSB TX
  (`SS` command, `qmx-cat.md:63`); that is a separate feature with its own
  latency and safety analysis.
- **Phone-side demodulation** and decoding (FT8, CW). Narrowband I/Q at ~48
  kbps would make it possible and the frame format does not preclude it, but
  v1 ships magnitudes only.
- **Recording** or export of spectrum data.
- **FT-891 / FTX-1 support.** No I/Q source exists on those radios.
