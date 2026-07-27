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

At the QMX's expected 48 kHz stereo 16-bit, raw I/Q is 1.54 Mbps — about 10×
what BLE can carry, so the decimation is not optional. Measured against a
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
- Streaming **auto-stops** on BLE disconnect and on USB detach. It is never
  persisted; a reconnecting central starts quiet.

**Capability discovery costs nothing new.** Firmware without the DSP path
answers `NAK` with `CTRL_ERR_UNSUPPORTED` — already defined at
`ctrl_proto.h:42` and currently unused. So the app probes by asking, and the
22-byte `STATUS` layout (protocol.md §3) does not change. No format-version
bump, no golden-vector churn on the existing status path.

### 3.3 Frame format

Little-endian, consistent with §2. Fragment 0 carries the header; continuation
fragments carry only enough to place their bins.

```
frag 0 : [seq:u8][frag:u8=0][nfrags:u8][first_bin:u16][bins_total:u16]
         [sample_rate_hz:u32][bin bytes…]            header = 11 B
frag n : [seq:u8][frag:u8][nfrags:u8][first_bin:u16][bin bytes…]
                                                     header =  5 B
```

- Bins are **dBFS at 0.5 dB/LSB**: `0` = full scale, `255` = −127.5 dBFS.
  128 dB of range, more than the radio has. No absolute calibration —
  the bridge cannot know the gain distribution ahead of it; the app applies a
  per-radio offset if it wants dBm.
- Bin 0 is the lowest frequency of the window; the centre bin is DC, i.e. the
  tuned frequency. Span is `sample_rate_hz`.
- `seq` increments per frame and wraps. The central **drops any frame whose
  fragments are incomplete or out of order** — no reassembly across sequence
  numbers, no retransmission.

At ATT_MTU 185, 256 bins is 2 fragments; the design tolerates any MTU ≥ 32.

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

Dropped frames are reported by reusing `EVT_OVERFLOW` (`0x83`) with a new
`which = 2` (spectrum), keeping its existing 1/s rate limit.

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

Interface selection already handles compositeness correctly and is unit-tested
with a QMX-shaped fixture — audio on 0/1/2, CDC comm on 3, data on 4, asserting
`cat_iface == 3` (`esp32s3/test/host/test_radio_detect.c:53-69`).

### 5.3 Enabling I/Q, and its cost to the user

`Q9` is session-only and not saved to EEPROM (`qmx-cat.md:105-106`), so the app
must re-issue it after every radio power cycle, and on reconnect if the radio
may have been cycled.

**The tradeoff must surface in the UI:** `Q9` streams I/Q *instead of*
demodulated audio. Turning the panadapter on therefore takes away the audio
that WSJT-X-style decoding uses on that same sound card
(`QMXMenuNotes.swift:32,86`). The user cannot have both at once. The app should
say so plainly rather than silently changing what the radio's USB audio means.

## 6. iOS design

| Layer | Addition |
|---|---|
| `CATBridgeCore/Spectrum/` | `SpectrumFrame` + reassembly: fragment ordering, sequence gaps, drop-on-incomplete. Pure, headless-testable, **no CoreBluetooth** (ios-implementation.md §3). |
| `CATBridgeBLE` | Subscribe `0006`; publish `AsyncStream<SpectrumFrame>`. `BridgeGATT.swift` gains the UUID. |
| `CATBridgeCore/Ctrl` | `SET_SPECTRUM` encode + `UNSUPPORTED` handling in `CtrlProtocol.swift`. |
| `QMXKit` | Panadapter session policy: issue `Q9`, re-issue after power cycle, map VFO frequency onto the axis, own the calibration offset. |
| `QMXUI` | Trace view + waterfall. |

Rendering: SwiftUI `Canvas` is adequate for a 256-bin trace at 15 fps. For a
scrolling waterfall with history, use a Metal texture and shift rows rather
than redrawing — the standard approach, and far cheaper.

Frequency labelling is the app's job (§1.1): it holds the VFO frequency, so
the axis is `vfo ± sample_rate/2`, adjusted for any offset the QMX applies in
I/Q mode. **Confirm on hardware whether the I/Q stream is centred on the VFO
or offset** — this is exactly the kind of radio-specific detail that belongs in
`QMXKit`, not the firmware.

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
  spectrum concurrently, asserting **CAT round-trip latency does not regress**
  and that frames drop (not queue) under induced backpressure.

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
| QMX config descriptor > 256 B | Total enumeration failure, silent | M0, before anything else |
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
