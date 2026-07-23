# ESP32-S3 BLE↔USB CAT Bridge — Implementation Plan

## 1. Purpose and Scope

Firmware for a **Seeed Studio XIAO ESP32S3** that acts as a transparent bridge
between a BLE central (an iOS app or any other remote device) and a transceiver's
USB CAT interface. Supported radios:

| Radio | CAT protocol | USB interface (expected) |
|---|---|---|
| Yaesu FT-891 | Yaesu ASCII CAT, `;`-terminated (FT-991A family syntax) | Silicon Labs **CP2105** dual UART (VID `0x10C4`, PID `0xEA70`). The **Enhanced** interface carries CAT; the Standard interface carries PTT/RTTY keying lines. |
| Yaesu FTX-1 | Yaesu ASCII CAT, `;`-terminated (FT-710/991A-era command set) | USB-C; to be confirmed at bring-up. Likely a **composite device** (USB audio codec + serial bridge, as on the FT-710). Assume SiLabs CP210x-family or CDC-ACM for the serial function; detection must therefore match per-interface, not per-device (§5.2). |
| QRP Labs QMX | Kenwood TS-480-style ASCII CAT, `;`-terminated | Native STM32 **USB CDC-ACM** (baud rate is ignored by the radio). |

**Design principle: the ESP32-S3 is a dumb pipe.** All CAT protocol knowledge —
command construction, response parsing, polling schedules, radio state models —
lives on the remote (iOS) side. The firmware only:

1. Enumerates the radio over USB host and opens its serial endpoint.
2. Shuttles bytes bidirectionally between that serial endpoint and BLE.
3. Exposes a small out-of-band control/status channel (baud rate, link state,
   radio identity) so the remote can configure the pipe without in-band tricks.

Everything conveniently testable without a radio must be testable without a radio.

Non-goals (v1): CAT command interpretation on the ESP32, multi-radio
simultaneous support, Wi-Fi, OTA (planned as a later phase), audio, and
**real-time CW keying**: BLE connection-interval jitter (tens of ms) makes
timing-accurate paddle/keyer emulation infeasible over this link. PTT and
CAT-initiated CW (e.g. Yaesu `KY`/memory keyer) work; element-timed keying is
explicitly out of scope and the docs must say so to head off feature requests.

---

## 2. Hardware

### 2.1 XIAO ESP32S3 in USB host mode

- The ESP32-S3's native USB-OTG (GPIO19 D-, GPIO20 D+) is routed to the XIAO's
  USB-C connector. In **host mode** this same connector talks to the radio.
- **VBUS sourcing caveat:** the XIAO's 5V rail feeds the USB-C VBUS through a
  Schottky diode in the *charge* direction only. To power a bus-powered device
  (the FT-891's CP2105 is bus-powered even though the radio has its own PSU):
  - Power the XIAO from its `5V`/`GND` pads (or BAT pads), **and**
  - Either bridge the VBUS diode (solder jumper) or use a USB-C OTG "Y" cable /
    powered adapter that injects 5 V on VBUS externally.
  - **Recommended default: the powered OTG cable**, because bridging the diode
    creates a second trap: with the diode bridged, plugging the XIAO into a PC
    while it is also bench-powered connects two 5 V supplies against each other.
    If the board *is* modified, the rule is "never both at once" and it must be
    printed in `docs/hardware.md` in bold.
  - Document the chosen approach with photos in `docs/hardware.md` during
    bring-up; this is the #1 "it doesn't enumerate" trap.
- **Console logging:** with the native USB in host mode, USB-CDC console is
  unavailable. Route logs to **UART0 (TX=GPIO43, RX=GPIO44)** and set
  `ESP_CONSOLE_UART_DEFAULT` in sdkconfig. A $3 USB-UART dongle becomes the dev
  console.
- **Flashing workflow:** the native USB port is occupied by host mode, so
  day-to-day flashing goes over the same UART0 dongle (hold BOOT at reset to
  enter the ROM UART downloader), which also keeps the console attached.
  Alternative: unplug the radio and use the native USB bootloader (BOOT+reset);
  fine for one-offs, annoying for iterative work. The bench runner (§7.7) must
  use the UART path so it never needs to touch the USB-C cable.
- LED: use the XIAO's user LED (GPIO21) for link-state signalling (§5.6).

### 2.2 Bench inventory needed for testing

- 1× XIAO ESP32S3 + USB-UART dongle for console.
- 1× USB-C OTG adapter with external power injection (or modified board).
- 1× **CP2105** board (e.g. SiLabs CP2105-EK eval kit) as the "fake FT-891":
  only a real CP2105 exercises the dual-interface path and the PID `0xEA70`
  match. A common CP2102 breakout does **not** — it enumerates as PID `0xEA60`,
  single interface, and lands in the generic CP210x profile. Keep a CP2102
  around anyway: it is the test vector for that generic (FTX-1-candidate) path.
- A second dev board flashed as a CDC-ACM echo/serial device to emulate the
  QMX enumeration path.
- Real radios for final hardware-in-the-loop passes.

---

## 3. Toolchain and Project Layout

- **ESP-IDF ≥ 5.2** (not Arduino): required for the maintained `usb_host` stack,
  the `esp-usb` VCP driver components, and NimBLE.
- Components from the [espressif/esp-usb](https://github.com/espressif/esp-usb)
  registry: `usb_host_cdc_acm`, `usb_host_cp210x`, `usb_host_ftdi_sio`
  (fallback), unified behind `usb_host_vcp`.
- BLE: **NimBLE** (smaller RAM footprint than Bluedroid; peripheral-only).

```
esp32s3/
├── docs/
│   ├── implementation.md        # this file
│   ├── protocol.md              # BLE GATT + control protocol spec (source of truth)
│   └── hardware.md              # wiring, VBUS mod, photos
├── firmware/
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults
│   ├── main/                    # app_main, task wiring, LED
│   └── components/
│       ├── cat_bridge/          # core: ring buffers, byte pump, stats
│       ├── usb_link/            # usb_host + VCP drivers, radio detection
│       ├── ble_link/            # NimBLE GATT server, MTU/chunking
│       └── ctrl_proto/          # control-channel codec (pure C, no deps)
├── test/
│   ├── host/                    # Linux-target unit tests (Unity/CMock)
│   ├── target/                  # on-device tests (pytest-embedded)
│   └── tools/
│       ├── radio_sim.py         # FT-891/FTX-1/QMX CAT simulator over a serial port
│       ├── ble_client.py        # bleak-based reference client + test driver
│       └── soak.py              # long-run stress driver
└── README.md
```

Pure-logic components (`ctrl_proto`, ring buffers in `cat_bridge`) must compile
on the Linux host with no FreeRTOS/IDF headers so they can be unit-tested off
target.

---

## 4. BLE Interface (GATT)

One primary service, Nordic-UART-style but with a separate control plane so the
CAT stream stays 100 % transparent (no escaping, no in-band commands).

**Service UUID:** `6e400001-b5a3-f393-e0a9-e50e24dcca9e`-style custom 128-bit
base (generate a project-specific base UUID; record it in `protocol.md`).

| Characteristic | Properties | Direction | Purpose |
|---|---|---|---|
| `CAT_RX` | Write / Write-No-Response | central → radio | Raw CAT bytes to forward to the radio. No framing; any byte sequence legal. |
| `CAT_TX` | Notify | radio → central | Raw CAT bytes from the radio. Chunked to `ATT_MTU − 3`. |
| `CTRL` | Write + Notify | both | TLV control messages (§4.1). |
| `STATUS` | Read + Notify | device → central | Packed status struct: USB link state, detected radio, baud, buffer stats, firmware version. Notified on change. First byte is a **format-version**; all multi-byte fields **little-endian**; layout frozen in `protocol.md`. |

Rules:

- Negotiate MTU up (iOS gives 185–517); never assume more than 20 bytes works.
- `CAT_TX` notifications coalesce: drain the radio→BLE ring buffer into maximal
  MTU-sized notifications, but flush on a small (5–10 ms) idle timeout, and
  optionally flush at once when the last byte received from the radio is `;`
  (all three radios terminate responses with `;`), keeping latency low without
  the ESP32 needing to understand the protocol beyond that single delimiter.
- Single central only. Concretely: **stop advertising on connect, resume on
  disconnect** — that *is* the rejection mechanism; there is no reliable way to
  "refuse" a central that was allowed to connect, so don't design for one.
- Security: this link can key a 100 W transmitter, so an open bridge is a
  safety problem, not a convenience question. **Release builds require LE
  encryption + bonding (Just Works) by default**; whether to step up to a
  passkey is an open question (§9). Open/unencrypted mode exists only behind a
  debug build flag and the LED signals it (§5.6). Bonded-peer allowlist of 1.

### 4.1 Control protocol (`CTRL` characteristic)

Tiny TLV: `[opcode:1][len:1][payload:len]`. Implemented in `ctrl_proto` as pure
functions (`encode`/`decode` over byte spans) → trivially unit-testable.

| Opcode | Dir | Payload | Semantics |
|---|---|---|---|
| `0x01 SET_BAUD` | C→P | u32 LE baud | Reconfigure VCP line coding (ignored/ack'd for CDC radios like QMX). |
| `0x02 GET_STATUS` | C→P | — | Respond with `STATUS` snapshot via `CTRL` notify. |
| `0x03 USB_RESET` | C→P | — | Force USB re-enumeration (recovery hammer). |
| `0x04 SET_LINE` | C→P | bitmap | Assert/deassert DTR/RTS (some rigs key PTT via these; QMX ignores). |
| `0x05 PURGE` | C→P | u8 mask | Flush TX and/or RX ring buffers. |
| `0x06 SET_FAILSAFE` | C→P | 0–32 raw bytes | Byte string the bridge writes to the radio **once, on BLE disconnect or supervision timeout** (e.g. the app sets `TX0;` after keying PTT, clears it after unkey). Empty payload disables. Protects against a dead app leaving the rig keyed while keeping protocol knowledge on the remote — the firmware never interprets the bytes. Not persisted; cleared on USB detach. |
| `0x80 ACK` / `0x81 NAK` | P→C | opcode + err code | Result of last command. |
| `0x82 EVT_USB` | P→C | state enum + radio id enum | USB attach/detach/enumerated events. |
| `0x83 EVT_OVERFLOW` | P→C | u8 which + u32 dropped | Buffer overflow report (§5.4). |

Every command gets exactly one ACK/NAK. The remote never needs to poll.

---

## 5. Firmware Architecture

### 5.1 Task model

```
┌────────────┐  attach/detach   ┌─────────────┐
│ usb_host    │ ───────────────▶ │             │
│ daemon task │                  │  bridge     │   rb_usb_to_ble    ┌──────────┐
├────────────┤   rx bytes       │  task       │ ─────────────────▶ │ ble_link │
│ vcp rx cb   │ ───────────────▶ │ (byte pump, │                    │ (NimBLE  │
└────────────┘                  │  ctrl exec, │ ◀───────────────── │  host    │
                                │  status)    │   rb_ble_to_usb    │  task)   │
                                └─────────────┘                    └──────────┘
```

- **usb task**: runs `usb_host_lib` events + VCP driver; owns enumeration and
  the radio-detect table. Received bytes go straight into `rb_usb_to_ble`
  (lock-free SPSC ring buffer) from the driver callback.
- **bridge task**: the only place with business logic. Pumps rings in both
  directions, executes CTRL opcodes, maintains status, drives the LED.
- **NimBLE host task**: standard NimBLE; GATT writes push into `rb_ble_to_usb`
  from the GATT callback (bounded copy only, no processing).

Static allocation throughout; no heap use on the datapath after init.

A notify attempt can fail when the controller is out of buffers
(`BLE_HS_ENOMEM`). Treat that as **backpressure, never as a drop**: leave the
bytes in `rb_usb_to_ble` and retry on the next tick/conn event. Only ring-full
(§5.4) may ever discard data, because only that path reports the loss.

### 5.2 Radio detection

Match table evaluated at enumeration. Matching is **per-interface**, not
per-device: modern rigs (FT-710, expected FTX-1) enumerate as composite
devices (USB audio + serial bridge), so `usb_link` walks the configuration
descriptor, skips non-serial interfaces (e.g. UAC audio), and matches the
first serial-capable interface against the table:

1. `VID 0x10C4 / PID 0xEA70` (CP2105) → **FT-891 profile**: open the
   *Enhanced* (ECI) interface — **interface #0** on the CP2105 (the Standard
   SCI is #1). Verify the CAT-is-on-Enhanced assumption against a real FT-891
   at bring-up before freezing this; getting it wrong silently connects to the
   PTT/RTTY port. Default **4800-8-N-1** — see baud note below.
2. `VID 0x10C4`, other CP210x PIDs → **generic Yaesu profile** (FTX-1 expected
   here until confirmed): default 4800.
3. Interface class `CDC-ACM` → **QMX/generic-CDC profile**: baud is cosmetic;
   still apply `SET_BAUD` so line coding requests succeed.
4. `VID 0x0403` (FTDI) → fallback generic profile.
5. Anything else → status `RADIO_UNSUPPORTED`; stay attached, report over CTRL.

**Baud default rationale:** the FT-891 ships with `05-06 CAT RATE = 4800`, so
the bridge must default to 4800 or a factory-fresh radio silently fails —
mismatched baud produces no error, just garbage/silence. The *app* owns baud
negotiation: probe with `ID;` at 38400 → 9600 → 4800 via `SET_BAUD` (cheap,
< 1 s worst case), then recommend the user raise the menu setting. The
firmware never auto-probes; that would be protocol knowledge.

The detected profile enum is surfaced in `STATUS`; the *remote* decides which
CAT dialect to speak. The profile only selects driver, interface index, and
default line coding — never protocol behavior.

### 5.3 Data path and sizing

CAT is slow (≤ 38400 baud ≈ 3.84 KB/s) and BLE with a 185-byte MTU at a 30 ms
connection interval comfortably exceeds that. Sizing:

- `rb_usb_to_ble`: 2048 B (≈ 0.5 s of worst-case radio chatter).
- `rb_ble_to_usb`: 1024 B.
- Notification flush: on `;`, on MTU-full, or on 8 ms idle — whichever first.

### 5.4 Overflow policy

Never block the BLE stack or the USB driver. On ring-full: drop **newest**
bytes, count them, and emit `EVT_OVERFLOW` (rate-limited to 1/s). A transparent
bridge that silently drops mid-stream corrupts CAT framing, so the remote must
be told; it recovers by re-polling (CAT is idempotent request/response).

### 5.5 Error handling & recovery

- USB detach (cable pull, radio off): tear down VCP cleanly, purge rings, emit
  `EVT_USB(detached)`, resume host-lib daemon waiting for attach. Re-attach is
  fully automatic; no reboot.
- USB stall/babble/driver error: one automatic port reset + re-enumerate; if it
  fails 3× in 10 s, back off to 5 s retry and report `USB_ERROR` state.
- BLE disconnect: **first** transmit the `SET_FAILSAFE` string to the radio,
  if one is armed (this is the stuck-PTT protection and must not race with the
  purge). Then keep USB open, purge `rb_ble_to_usb` only, keep filling
  `rb_usb_to_ble` for ≤ 1 s then purge (stale data is useless).
- Watchdog on bridge + usb tasks; brownout handler logs to RTC memory and the
  reset reason is included in `STATUS` after boot.

### 5.6 LED states (GPIO21)

| Pattern | Meaning |
|---|---|
| slow blink (1 Hz) | idle: no BLE, no USB |
| double-blink | USB radio enumerated, no BLE central |
| solid | BLE connected + radio enumerated (bridge live) |
| fast blink (5 Hz) | fault (USB error state) |
| triple-blink burst every 3 s | **debug build with BLE security disabled** (visible reminder; never ships) |

### 5.7 Configuration & persistence

NVS namespace `catbridge`: BLE device name suffix, default baud, security mode.
All settable via CTRL opcodes in a later phase; v1 ships compile-time defaults
plus `SET_BAUD` at runtime (not persisted).

---

## 6. iOS-Facing Contract (informative)

The firmware treats these as requirements, the app implements them:

- App speaks Yaesu CAT to FT-891/FTX-1 and Kenwood-style CAT to QMX, selected
  by the `STATUS` radio-id enum.
- App owns polling cadence, retries, and timeouts (recommend: command timeout
  300 ms, single retry, then surface error).
- App must handle `EVT_OVERFLOW` by discarding any partial response buffer and
  re-issuing the last poll.
- Write-No-Response for CAT writes; the ACK'd `CTRL` path exists for anything
  that must be reliable. On iOS, respect
  `canSendWriteWithoutResponse`/`peripheralIsReady` — CoreBluetooth silently
  queues-then-drops WNR floods.
- Before any PTT-on command, arm `SET_FAILSAFE` with the matching PTT-off
  string; disarm after unkey. The firmware's disconnect behavior depends on the
  app doing this.
- The firmware advertises the primary service UUID **in the advertising
  payload** (not only in the GATT table) so iOS background scanning /
  state-restoration can rediscover the bridge; the app scans by that UUID.
- bleak-on-Linux behavior is not CoreBluetooth behavior (MTU offers, WNR
  throttling, backgrounding). The harness in §7.3 is necessary but not
  sufficient — §7.5 includes a pass driven from a physical iOS device.

`docs/protocol.md` is the normative spec both sides code against; it gets
updated in the same PR as any firmware protocol change.

---

## 7. Testing Strategy

Layered so that ~90 % of logic is verified without a radio and ~99 % without a
human.

### 7.1 Host-based unit tests (CI, no hardware)

Run with Unity/CMock on the Linux target (`idf.py --preview set-target linux`
or plain CMake for the pure components). Cover:

- `ctrl_proto`: encode/decode round-trips, truncated/garbage TLVs, unknown
  opcodes → NAK, boundary lengths (0, 1, 255), fuzz with libFuzzer harness.
- Ring buffers: SPSC correctness under simulated interleavings, wrap-around,
  overflow counting, purge semantics.
- Notification coalescer: given scripted byte-arrival timelines, assert flush
  boundaries (`;`, MTU-full, idle timer) and max-latency bound.
- Radio-detect table: VID/PID/class fixtures → expected profile, interface
  index, default line coding (includes CP2105 Enhanced-vs-Standard selection).

Gate: 100 % of these run in GitHub Actions on every PR.

### 7.2 On-target component tests (pytest-embedded, bench CI)

Flash a test app on a bare XIAO (no radio needed):

- Boot, NimBLE up, advertise, connect from test host (see 7.3), MTU negotiation
  at 23 / 185 / 517.
- CTRL command matrix: every opcode → correct ACK/NAK, `GET_STATUS` fields sane.
- USB host with **no device attached**: state machine sits in `waiting`,
  `USB_RESET` NAKs gracefully.

### 7.3 BLE integration harness (`test/tools/ble_client.py`)

Python + `bleak` on a Linux/macOS test host. Doubles as the reference client
implementation. Test cases:

- Echo throughput: with the loopback rig (7.4), push 100 KB each direction,
  assert zero loss, measure goodput (target ≥ 2× 38400 baud) and round-trip
  latency (target: median < 60 ms with 30 ms conn interval).
- Chunking: responses of length 1, MTU−3, MTU−2, MTU−1, MTU, 3×MTU+1.
- Disconnect storms: 50 connect/disconnect cycles, no leaks (heap watermark via
  `STATUS`), advertising always resumes ≤ 2 s.
- Second-central behavior: advertising stops while connected, resumes on
  disconnect (scan trace proves it).
- Write flood past ring capacity → `EVT_OVERFLOW` received, counts match.
- Failsafe: arm `SET_FAILSAFE("TX0;")`, hard-drop the BLE link (kill the client
  process, don't disconnect cleanly), assert the loopback/simulator receives
  exactly `TX0;` within the supervision timeout + 100 ms; repeat with a clean
  disconnect and with failsafe disarmed (nothing must be sent).
- Bonding path: pair, bond, reconnect encrypted, reject unbonded second
  device (release-build config).

### 7.4 Hardware-in-the-loop with a **radio simulator** (no radio)

`test/tools/radio_sim.py` runs on the test host attached to the ESP32's USB
host port through the CP2105 eval board (FT-891 dual-interface path), a CP2102
breakout (generic-CP210x path), or a CDC dev board (QMX path) — three distinct
enumeration fixtures, per §2.2. It emulates each radio's personality:

- FT-891/FTX-1 mode: `;`-terminated Yaesu grammar — answers `FA;` `MD0;` `IF;`
  `TX;`/`RX;` etc. with realistic timing (per-char delay at the configured
  baud), rejects malformed input with `?;` like real Yaesu firmware.
- QMX mode: Kenwood grammar (`FA;` `IF;` `TQ;`…), instant responses, ignores
  line coding.
- Fault injection flags: no-response, partial response then stall, response
  split across odd USB packet boundaries, garbage bursts, mid-command detach
  (via a USB power-switch relay or data-line mux if available).

End-to-end suite = `ble_client.py` (BLE side) + `radio_sim.py` (USB side)
scripted together: full poll cycles, baud changes mid-session, USB replug
recovery, 1000-command sequences with CRC-checked payload journaling on both
ends to prove byte-perfect transparency.

### 7.5 Real-radio acceptance checklist (manual, per radio)

Documented as a runnable checklist in `docs/testing-acceptance.md`:

1. Enumerate; `STATUS` reports correct radio id and CP2105 Enhanced port
   (FT-891). **First-ever FT-891 session: empirically confirm CAT answers on
   the Enhanced (ECI, interface #0) port and update §5.2 if it doesn't.**
2. From reference client: read frequency (`FA;`), set frequency, change mode,
   PTT on/off via CAT (`TX1;`/`TX0;` Yaesu, `TQ1;`/`TQ0;` QMX ‑ confirm),
   verify on the radio's display/RF output into a dummy load.
3. Failsafe against the real radio: arm `SET_FAILSAFE("TX0;")`, key PTT via
   CAT, power off the BLE client mid-transmit → radio unkeys within the
   supervision timeout.
4. All three CAT RATE settings on FT-891 via `SET_BAUD`, including the
   out-of-box case: factory-default radio (4800) works with zero configuration.
5. Cable pull mid-poll → auto-recovery, app resumes.
6. RF immunity: key 100 W (FT-891) into dummy load with bridge inline; no
   resets, no corrupt bytes (journal check). Repeat on 40 m/20 m/10 m.
7. Repeat a representative subset from a **physical iOS device** (TestFlight
   build of the app or reference screens): connect, bond, background/foreground
   the app, poll loop survives a locked phone — bleak on Linux/macOS does not
   stand in for CoreBluetooth (§6).

### 7.6 Soak & robustness

- 24 h run: simulator + BLE client polling `IF;` at 5 Hz; assert zero watchdog
  resets, flat heap watermark, overflow count 0.
- Power-cycle loop: 200 cold boots, assert time-to-advertising < 3 s each.
- BLE range/interference: run soak at RSSI ≈ −85 dBm (attenuated), loss handled
  by link layer, no application-visible corruption.

### 7.7 CI summary

| Stage | Where | Trigger |
|---|---|---|
| Build (all configs) + host unit tests + fuzz smoke (60 s) | GitHub Actions | every PR |
| Target component tests | self-hosted bench runner | every PR (label-gated) |
| Full HIL (7.3 + 7.4) | bench runner | nightly + release tags |
| Soak | bench runner | weekly + release candidates |

---

## 8. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| M0 | Repo scaffold, CI build, console on UART0, LED task | Green CI; blink on bench |
| M1 | `ctrl_proto` + ring buffers + host unit tests | 7.1 suite green |
| M2 | NimBLE service, MTU/chunking, CTRL/STATUS; **`protocol.md` first normative draft** | 7.2 + BLE echo (firmware-internal loopback) green; protocol.md reviewed — it must exist *before* the iOS app codes against the interface, not at M7 |
| M3 | USB host + VCP drivers + per-interface radio detect | Enumerates CP2105 eval board (dual-interface, FT-891 profile), CP2102 (generic), CDC board (QMX); profiles + interface selection correct |
| M4 | Full bridge datapath + overflow/recovery + failsafe | 7.3 + 7.4 suites green |
| M5 | BLE security (bonding, allowlist, debug-open flag + LED) | 7.3 bonding cases green |
| M6 | Real-radio acceptance (FT-891, QMX) | 7.5 checklist signed off, incl. iOS-device pass |
| M7 | FTX-1 bring-up (confirm USB identity, adjust table) | 7.5 on FTX-1 |
| M8 | Hardening: soak, RF immunity, docs | 7.6 green; protocol.md v1.0 tagged |

## 9. Open Questions (resolve during bring-up)

1. FTX-1 USB enumeration identity (VID/PID/class, composite layout) — blocks
   only M7; the per-interface driver matrix already covers the likely outcomes.
2. Empirical confirmation that FT-891 CAT is on the CP2105 Enhanced/ECI
   interface (#0) — resolve at first real-radio session (7.5 item 1).
3. Whether any target radio requires DTR/RTS asserted to accept CAT (drives
   default state of `SET_LINE`).
4. VBUS strategy for the "product" build: powered OTG cable (recommended) vs.
   board mod — decide before M6 so acceptance runs on the shipping topology.
5. BLE bonding is settled as the release default (§4); open question is only
   whether to require a passkey instead of Just Works — decide before M5.
