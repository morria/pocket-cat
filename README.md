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
enclosure/          3D-printable case for the XIAO board (SCAD + STL)
docs/               system-level reports + library implementation plan
```

## Building

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
