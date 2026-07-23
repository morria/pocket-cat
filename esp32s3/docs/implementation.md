# ESP32-S3 BLE↔USB CAT Bridge — Implementation Plan

## 1. Purpose and Scope

Firmware for a **Seeed Studio XIAO ESP32S3** that acts as a transparent bridge
between a BLE central (an iOS app or any other remote device) and a transceiver's
USB CAT interface. Supported radios:

| Radio | CAT protocol | USB interface (expected) |
|---|---|---|
| Yaesu FT-891 | Yaesu ASCII CAT, `;`-terminated (FT-991A family syntax) | Silicon Labs **CP2105** dual UART (VID `0x10C4`, PID `0xEA70`). The **Enhanced** interface carries CAT; the Standard interface carries PTT/RTTY keying lines. |
| Yaesu FTX-1 | Yaesu ASCII CAT, `;`-terminated (FT-710/991A-era command set) | USB-C; to be confirmed at bring-up. Assume SiLabs CP210x-family or CDC-ACM; the driver matrix below covers both. |
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
simultaneous support, Wi-Fi, OTA (planned as a later phase), audio.

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
  - Document the chosen approach with photos in `docs/hardware.md` during
    bring-up; this is the #1 "it doesn't enumerate" trap.
- **Console logging:** with the native USB in host mode, USB-CDC console is
  unavailable. Route logs to **UART0 (TX=GPIO43, RX=GPIO44)** and set
  `ESP_CONSOLE_UART_DEFAULT` in sdkconfig. A $3 USB-UART dongle becomes the dev
  console.
- LED: use the XIAO's user LED (GPIO21) for link-state signalling (§5.6).

### 2.2 Bench inventory needed for testing

- 1× XIAO ESP32S3 + USB-UART dongle for console.
- 1× USB-C OTG adapter with external power injection (or modified board).
- 1× CP2102/CP2105 breakout ("fake radio" — enumerates identically to the
  FT-891's bridge chip) wired to a PC running the radio simulator (§7.4).
- Optionally: a second dev board flashed as a CDC-ACM echo device to emulate
  the QMX enumeration path.
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
| `STATUS` | Read + Notify | device → central | Packed status struct: USB link state, detected radio, baud, buffer stats, firmware version. Notified on change. |

Rules:

- Negotiate MTU up (iOS gives 185–517); never assume more than 20 bytes works.
- `CAT_TX` notifications coalesce: drain the radio→BLE ring buffer into maximal
  MTU-sized notifications, but flush on a small (5–10 ms) idle timeout, and
  optionally flush at once when the last byte received from the radio is `;`
  (all three radios terminate responses with `;`), keeping latency low without
  the ESP32 needing to understand the protocol beyond that single delimiter.
- Single central only; reject/ignore a second connection attempt (v1).
- Pairing: Just Works LE encryption optional and configurable; default open for
  v1 bring-up, with a build flag to require bonding before ship.

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

### 5.2 Radio detection

Match table evaluated at enumeration, in order:

1. `VID 0x10C4 / PID 0xEA70` (CP2105) → **FT-891 profile**: open the *Enhanced*
   interface (interface #1 on CP2105) for CAT; default 38400-8-N-1 (recommend
   users set menu `05-06 CAT RATE = 38400`; remote can `SET_BAUD` to 4800/9600).
2. `VID 0x10C4`, other CP210x PIDs → **generic Yaesu profile** (FTX-1 expected
   here until confirmed): single interface, default 38400.
3. USB class `CDC-ACM` → **QMX/generic-CDC profile**: baud is cosmetic; still
   apply `SET_BAUD` so line coding requests succeed.
4. `VID 0x0403` (FTDI) → fallback generic profile.
5. Anything else → status `RADIO_UNSUPPORTED`; stay attached, report over CTRL.

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
- BLE disconnect: keep USB open, purge `rb_ble_to_usb` only, keep filling
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
  that must be reliable.

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
- Second-central rejection.
- Write flood past ring capacity → `EVT_OVERFLOW` received, counts match.

### 7.4 Hardware-in-the-loop with a **radio simulator** (no radio)

`test/tools/radio_sim.py` runs on the test host attached to the ESP32's USB
host port through a CP2102/CP2105 breakout (FT-891 path) or a CDC dev board
(QMX path). It emulates each radio's personality:

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

1. Enumerate; `STATUS` reports correct radio id and CP2105 Enhanced port (FT-891).
2. From reference client: read frequency (`FA;`), set frequency, change mode,
   PTT on/off via CAT (`TX1;`/`TX0;` Yaesu, `TQ1;`/`TQ0;` QMX ‑ confirm),
   verify on the radio's display/RF output into a dummy load.
3. All three CAT RATE settings on FT-891 via `SET_BAUD`.
4. Cable pull mid-poll → auto-recovery, app resumes.
5. RF immunity: key 100 W (FT-891) into dummy load with bridge inline; no
   resets, no corrupt bytes (journal check). Repeat on 40 m/20 m/10 m.

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
| M2 | NimBLE service, MTU/chunking, CTRL/STATUS | 7.2 + BLE echo (firmware-internal loopback) green |
| M3 | USB host + VCP drivers + radio detect | Enumerates CP2102 breakout and CDC board; profiles correct |
| M4 | Full bridge datapath + overflow/recovery | 7.3 + 7.4 suites green |
| M5 | Real-radio acceptance (FT-891, QMX) | 7.5 checklist signed off |
| M6 | FTX-1 bring-up (confirm USB identity, adjust table) | 7.5 on FTX-1 |
| M7 | Hardening: soak, RF immunity, security flag, docs | 7.6 green; protocol.md v1.0 tagged |

## 9. Open Questions (resolve during bring-up)

1. FTX-1 USB enumeration identity (VID/PID/class, single vs dual interface) —
   blocks only M6; the driver matrix already covers the likely outcomes.
2. Whether any target radio requires DTR/RTS asserted to accept CAT (drives
   default state of `SET_LINE`).
3. VBUS strategy for the "product" build: board mod vs. powered OTG cable.
4. Ship default for BLE security (open vs. bonded) — decide before M7.
