# Pocket Cat

Control your HF transceiver from an iPhone. Pocket Cat is a small
BLE↔USB bridge — a Seeed XIAO ESP32-S3 plugged into the radio's USB CAT
port — plus a Swift library (`CATBridgeKit`) that gives iOS apps a typed,
observable model of the rig: frequency, mode, PTT, RF power, a catalog of
rig settings (gains, squelch, keyer speed, NB/NR, preamp, attenuator,
filter width …), and Yaesu menu items, over Bluetooth LE — with raw CAT
kept only as an escape hatch.

Built for portable operation: radios like the FT-891 have full CAT
control but no Bluetooth. Pocket Cat adds it without putting any radio
logic in the firmware.

## Supported radios

| Radio | CAT dialect | USB interface |
|---|---|---|
| Yaesu FT-891 | Yaesu ASCII (`;`-terminated) | CP2105 dual UART |
| Yaesu FTX-1 | Yaesu ASCII (`;`-terminated) | CP210x/CDC (confirmed at bring-up) |
| QRP Labs QMX | Kenwood TS-480 subset | Native CDC-ACM |

## How it works

```
iOS app ──(SwiftUI/@Observable)── CATBridgeKit
                                      │  BLE GATT (bonded, encrypted)
                              XIAO ESP32-S3 bridge
                                      │  USB host (CDC-ACM / CP210x)
                                   radio CAT port
```

**The bridge is a dumb pipe.** The firmware enumerates the radio over USB
host, shuttles bytes between USB and BLE, and exposes a small control
channel (baud, link state, radio identity, failsafe). All CAT protocol
knowledge — command encoding, response parsing, polling, state modeling —
lives in `CATBridgeKit`. New radio support is a Swift change; the firmware
doesn't care.

An app's complete state-and-control loop:

```swift
import CATBridgeKit

let central = CATBridgeCentral()
let bridge = await central.bridges().first { _ in true }!
let session = try await central.connect(to: bridge) // pairs, probes baud,
                                                    // picks dialect, arms failsafe
Text(session.state.frequency?.description ?? "—")   // bind UI to state
try await session.set(frequency: 14_074_000)        // send commands
```

Because the BLE link can key a 100 W transmitter, the release firmware
requires LE Secure Connections bonding before accepting any CAT or control
writes, and a dead-man failsafe drops PTT if the link goes quiet.

## What to buy

A complete unit is a XIAO ESP32-S3, a small LiPo cell, a boost converter to
feed 5 V back to the radio's USB port, a slide switch, and two printed
parts. Full part numbers, dimensions, and substitution notes are in
[`BOM.md`](BOM.md); this is the shopping summary.

| Qty | Item | Notes |
|---|---|---|
| 1 | Seeed XIAO ESP32-S3 | Must be the version with the U.FL connector — there is no onboard antenna |
| 1 | FPC antenna, 2.4 GHz, 37 × 18 mm | Ships with the XIAO |
| 1 | LiPo cell, 602535, 3.7 V 500 mAh | 25 × 37 × 6 mm; the JST plug gets cut off |
| 1 | TPS61023 boost module | Adafruit MiniBoost or clone; do **not** fit the pin header |
| 1 | Slide switch, SS12F15G5 | SPDT, 19.8 mm frame, ⌀2.2 mm holes |
| 1 | M3 × 10 socket head cap screw + M3 nut | M3 × 12 also fits; no washer |
| ~500 mm | 26 AWG stranded hookup wire, 2 colours | 7 runs at ~60 mm |
| 1 | USB-C cable to the radio | Type and length depend on the rig's CAT port |
| ~23 g | PETG filament | Both printed parts, 4 walls / 25 % infill |

Also needed but not part of the unit: a **USB-to-UART dongle** for flashing.
The XIAO's native USB-C port runs in host mode to talk to the radio, so the
console and the bootloader live on UART0 (GPIO43/44) — see
[`esp32s3/README.md`](esp32s3/README.md).

Consumables: hot glue (strain relief on the BAT pads), foam tape or CA
(boost module and switch), isopropyl alcohol (antenna bay prep). Optional
for HF noise: a clip-on ferrite for the USB lead and copper foil tape to
line the lid over the boost.

## Building the hardware

The enclosure is two printed parts plus one bolt, closed size 57.2 × 47.2
× 18.9 mm. [`enclosure/README.md`](enclosure/README.md) has the full
step-by-step — layout, printing notes, numbered assembly, and a table of
`.scad` parameters to tune if a part doesn't fit. The shape of the job:

1. **Print** `enclosure/pocket_cat_base.stl` and
   `enclosure/pocket_cat_lid.stl` in PETG at 0.2 mm, 4 walls, 25 % infill.
   No supports. Regenerate them from `pocket_cat_case.scad` if you changed
   a parameter.
2. **Flash and smoke-test the XIAO first**, on the bench with the UART
   dongle. The pads are awkward to reach once the board is seated in the lid
   pocket component-side down.
3. **Fit the base** — FPC antenna glued into the right bay, slide switch on
   its two pegs, U.FL pigtail over the divider rib, cell laid in the left
   bay loose (never glued, and never packed into the 1 mm swelling gap).
4. **Fit the lid** — XIAO into the board pocket connector-first, boost
   module into its cradle.
5. **Wire it**, allowing 60 mm per run so the lid can lie flat for service.
   The switch goes upstream of *both* loads: cell + → switch common →
   XIAO BAT+ **and** boost Vin. That way switching off also kills the
   boost, so its 5 V output can't fight a host's VBUS when you plug a PC
   into the USB-C port to reflash. Twist every pair — loop area is what
   radiates.
6. **Close it** — lid skirt inside the base walls, M3 in from underneath,
   snug only.

The case is IP00: open USB aperture, open switch slot, unsealed parting
line. Bag and bench use.

## Building the software

Firmware (see [`esp32s3/README.md`](esp32s3/README.md) for flashing details
— the native USB-C port runs in host mode, so console lives on UART0):

```sh
cd esp32s3/firmware
idf.py set-target esp32s3
idf.py build flash
```

iOS library — add as a Swift Package dependency (iOS 17+ / macOS 14+):

```swift
.package(url: "https://github.com/morria/pocket-cat.git", from: "1.0.0")
```

then `import CATBridgeKit`.

## Repository layout

```
esp32s3/            bridge side
  firmware/         ESP-IDF (≥5.2) project for the XIAO ESP32-S3
  test/host/        C unit + end-to-end simulation suites (gcc, ASan/UBSan)
  test/tools/       radio_sim.py, ble_client.py, soak.py bench tools
  docs/             implementation plan, BLE protocol spec (normative)
Package.swift       Swift package manifest (swift-tools 6.0; iOS 17 / macOS 14)
Sources/            CATBridgeCore (pure logic) + CATBridgeBLE (CoreBluetooth)
Tests/
BOM.md              bill of materials for one unit
enclosure/          3D-printable case — pocket_cat_case.scad + base/lid STLs,
                    with printing and assembly instructions
docs/               system-level reports + library implementation plan
```

## Testing

```sh
make -C esp32s3/test/host run            # C suites: unit + e2e simulation
python -m pytest esp32s3/test/tools -q   # codec, radio_sim, pty rig tests
swift test
```

The BLE wire format is pinned by a golden vector file byte-compared across
the firmware and Swift codebases in CI. Hardware-in-the-loop bench tools
(`radio_sim.py`, `ble_client.py`, `soak.py`) are described in
`esp32s3/docs/implementation.md` §7.

## Status

All layers build and pass CI (ESP-IDF v5.3 target build, 57 C tests,
32 Python tests, 56 Swift tests), and the firmware runs on real XIAO
ESP32-S3 hardware — advertising, bonding policy, and the status channel
verified over the air. Radio bring-up (FT-891 first) is next; see
[`docs/completeness-report.md`](docs/completeness-report.md) for exactly
what is and isn't yet proven on hardware.
