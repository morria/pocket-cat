# Building a Pocket Cat

Start-to-finish instructions for building one unit: a BLE↔USB CAT bridge in a
printed case, plus an iOS app to drive it.

Each step below says what to do, how to know it worked, and where the detail
lives. Follow them in order — the firmware is flashed **before** assembly,
because the board's programming pads face into the case once it's built.

| Step | You need | Detail |
|---|---|---|
| [0. Prerequisites](#0-prerequisites) | a Mac, a 3D printer, a soldering iron | — |
| [1. Buy the parts](#1-buy-the-parts) | a handful of parts, some slow to ship | [`BOM.md`](BOM.md) |
| [2. Print the case](#2-print-the-case) | PETG, ~23 g | [`enclosure/README.md`](enclosure/README.md) |
| [3. Flash the firmware](#3-flash-the-firmware) | USB-UART dongle | [`esp32s3/README.md`](esp32s3/README.md) |
| [4. Solder the wiring](#4-solder-the-wiring) | fine-tip iron, 26 AWG wire | [`enclosure/README.md`](enclosure/README.md#assembly) |
| [5. Assemble the case](#5-assemble-the-case) | M3 hex key | [`enclosure/README.md`](enclosure/README.md#assembly) |
| [6. Build and install the app](#6-build-and-install-the-app) | Xcode, an Apple ID | [`ios/`](ios/) |
| [7. First contact](#7-first-contact) | the radio | — |

Steps 2 and 3 need nothing from each other — print while you wait for parts,
and flash as soon as the board arrives.

---

## 0. Prerequisites

**Hardware you must already own**

- A 3D printer that can run PETG (or PLA — see step 2).
- A temperature-controlled soldering iron with a fine tip. The XIAO's BAT pads
  are small and lift if you dwell on them.
- A multimeter. Not optional: you will check the boost converter's output
  before it goes anywhere near the microcontroller.
- A Mac, for the iOS app. The firmware alone builds on Linux too.

**Software**

| Tool | For | Install |
|---|---|---|
| ESP-IDF ≥ 5.2 (CI uses 5.3) | firmware | [Espressif's getting-started guide](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/) |
| Xcode 15 or later | iOS app | Mac App Store |
| `xcodegen` | generating the app project | `brew install xcodegen` |
| Python 3 + `pytest pytest-timeout pyserial` | firmware bench tools and their tests | `python3 -m pip install pytest pytest-timeout pyserial` |
| A slicer (PrusaSlicer, Cura, Bambu Studio, …) | the case | vendor site |
| OpenSCAD | *only* if you change the case dimensions | `brew install --cask openscad` |

After installing ESP-IDF, every new shell needs its environment:

```sh
. $HOME/esp/esp-idf/export.sh      # adjust to wherever you cloned it
```

**Checkpoint:** `idf.py --version` prints ≥ 5.2, `xcodegen --version` prints a
version, and `xcodebuild -version` prints Xcode 15+.

---

## 1. Buy the parts

Everything, with quantities, dimensions, substitutions and where to buy it, is
in **[`BOM.md`](BOM.md)**. The short version — one XIAO ESP32-S3, one 602535
LiPo cell, one TPS61023 boost module, one SS12F15G5 slide switch, an M3 bolt
and nut, and some 26 AWG wire.

Three things that trip people up, all covered in the BOM:

- The XIAO must be the version with the **U.FL antenna connector**. There is no
  onboard antenna; a board without it will advertise but barely reach across a
  desk.
- The boost module ships with a **pin header. Do not fit it** — the cradle in
  the lid has no room for it.
- You also need a **USB-to-UART dongle** to flash. It is not part of the
  finished unit, so it's easy to miss when ordering.

**Checkpoint:** parts on the bench, and the cell measures no more than 6 mm
thick. Thicker cells need `bat_z` changed and the base reprinted.

---

## 2. Print the case

Two parts, no supports:

- `enclosure/pocket_cat_base.stl`
- `enclosure/pocket_cat_lid.stl`

Settings: **PETG, 0.4 mm nozzle, 0.2 mm layer, 4 walls, 25 % infill.** About
23 g total, a few hours. Both parts are pre-oriented in the STLs — base floor
down, lid top face down. Slice as exported; do not rotate them.

PLA works if that's what you have, but the case sits in a bag with a battery in
it and PETG tolerates a hot car far better.

If you changed anything in `pocket_cat_case.scad`, regenerate first:

```sh
cd enclosure
openscad -o pocket_cat_base.stl -D 'part="base"' pocket_cat_case.scad
openscad -o pocket_cat_lid.stl  -D 'part="lid"'  pocket_cat_case.scad
```

Then clean up the two switch pegs on the base's right wall with a blade. They
print as horizontal features and sag slightly on their undersides — take
material off the bottom first. The switch frame should drop on without forcing.

**Checkpoint:** the lid's skirt slides inside the base walls, the switch frame
sits on both pegs, and the M3 nut slides into its slot in the lid boss.

Full printing notes, tolerances, and the parameter table for adjusting the fit:
[`enclosure/README.md`](enclosure/README.md#printing).

---

## 3. Flash the firmware

**Do this before soldering anything.** The XIAO's programming pads face into
the lid pocket once assembled, and the native USB-C port is used for the radio,
not for flashing.

Wire the USB-UART dongle to the board — three connections, and note TX goes to
RX:

| Dongle | XIAO ESP32-S3 |
|---|---|
| TX | GPIO44 (RX) |
| RX | GPIO43 (TX) |
| GND | GND |

Then build and flash:

```sh
cd esp32s3/firmware
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/tty.usbserial-XXXX flash monitor
```

Find your port with `ls /dev/tty.usb*` (macOS) or `ls /dev/ttyUSB*` (Linux). If
flashing fails to start, hold **BOOT**, tap **RESET**, release BOOT — that
enters the ROM downloader — and run the flash command again.

Run the test suites too — they need no hardware:

```sh
make -C esp32s3/test/host run            # C: unit + end-to-end simulation
python3 -m pytest esp32s3/test/tools -q  # Python: codec, radio_sim, pty rig
```

**Checkpoint:** `idf.py monitor` shows the bridge booting, and the board
advertises as `CATBridge-XXXX` in any BLE scanner app.

Console details, the debug build without BLE bonding, and the
hardware-in-the-loop tools: [`esp32s3/README.md`](esp32s3/README.md).

---

## 4. Solder the wiring

Seven runs, about 60 mm each so the lid can lie flat for servicing. Twist each
pair tightly — loop area is what radiates into the receiver.

| From | To |
|---|---|
| Cell + | Switch common |
| Switch output | XIAO BAT+ |
| Switch output | Boost Vin |
| Cell − | XIAO BAT− |
| Cell − | Boost GND |
| Boost 5V | XIAO VUSB |
| Boost GND | XIAO GND |

The switch sits upstream of **both** loads. That is deliberate: switching off
also kills the boost, so its 5 V output cannot back-feed a host's VBUS when you
plug a PC into the USB-C port to reflash.

**Order matters, and one step is genuinely dangerous:**

1. **Cut the cell's JST plug off one lead at a time.** Cutting both at once
   shorts the cell through your cutters. A 500 mAh LiPo will happily weld them.
2. Solder the cell leads to BAT+ and BAT− on the underside of the XIAO, bend
   the wires flat immediately, and put hot glue over the joint. Those pads lift
   if a wire is ever tugged.
3. Wire the switch and the boost input.
4. **Before connecting the boost output to the XIAO**, switch on and measure
   the boost's output with your multimeter. It must read 5 V. If it reads 0 V,
   check whether `En` has a pull-up on your module — if not, tie it to Vin.
5. Only then solder boost 5V/GND to VUSB/GND.

**Checkpoint:** switch on, and the XIAO's LED lights and it still advertises
over BLE. Switch off, and everything goes dark — including the boost.

---

## 5. Assemble the case

Base first, then lid, then close:

1. Wipe the antenna bay with IPA and stick the FPC antenna down against its
   backstop rib.
2. Fit the slide switch on its two pegs, actuator through the slot, and glue.
3. Route the U.FL pigtail over the divider rib through the notch at y = 34.
4. Lay the cell in the left bay. **Do not glue it, and do not pack anything
   into the 1 mm space above it** — that's the pouch's swelling allowance. If
   it rattles, tape across it and stick the tape to the bay walls, never to the
   pouch.
5. Press the XIAO into the lid pocket, connector into the aperture first, then
   the rear edge past the retention ramps.
6. Press the boost module into its cradle, pad edge facing the board.
7. Dress the battery leads out through the wire channel and hook them round the
   anchor posts.
8. Lower the lid — the skirt slides inside the base walls — then fit the M3
   from underneath and snug it. **Snug only.** The skirt carries the shear; the
   bolt only resists lift.

**Checkpoint:** nothing protrudes from either outer face, the switch moves
through its full throw without binding, and the USB-C port is centred in its
aperture.

Numbered detail, the layout rationale, and what to change if a part doesn't
fit: [`enclosure/README.md`](enclosure/README.md#assembly).

---

## 6. Build and install the app

Pick the app for your radio:

| Radio | App |
|---|---|
| Yaesu FT-891 | [`ios/pocket-cat-ft891`](ios/pocket-cat-ft891) |
| QRP Labs QMX | [`ios/pocket-cat-qmx`](ios/pocket-cat-qmx) |

Both build the same way. Using the FT-891 app as the example:

```sh
cd ios/pocket-cat-ft891
swift test                       # headless tests, no hardware needed
cd App && xcodegen generate      # creates FT891.xcodeproj
open FT891.xcodeproj             # run the FT891App scheme
```

**You must set your own signing team.** Find your team ID:

```sh
security find-certificate -c "Apple Development" -p |
  openssl x509 -noout -subject | tr ',' '\n' | grep OU
```

In Xcode, select the app target → Signing & Capabilities → your team. Then run
to your iPhone with the device selected.

You can also install from the command line without opening Xcode:

```sh
xcrun devicectl list devices     # find your device's identifier
xcodebuild build -project FT891.xcodeproj -scheme FT891App \
  -destination 'id=YOUR-DEVICE-ID' -derivedDataPath build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOURTEAMID
xcrun devicectl device install app --device YOUR-DEVICE-ID \
  build/Build/Products/Debug-iphoneos/FT891App.app
```

**If signing fails on the iCloud entitlement** — "provisioning profile doesn't
match the entitlements file's values for the
`com.apple.developer.ubiquity-container-identifiers`" — your team has no iCloud
container for the app. Either add one in Xcode (target → Signing &
Capabilities → + iCloud), or build without it and let profiles fall back to
on-device storage:

```sh
CODE_SIGN_ENTITLEMENTS=FT891App/FT891App-NoCloud.entitlements
```

**Checkpoint:** the app launches and Connection → **Simulated FT-891** (or
Simulated QMX) runs the entire app with no hardware attached. Do this before
touching the radio — it separates app problems from link problems.

---

## 7. First contact

1. Plug the bridge into the radio's USB CAT port and switch the bridge on.
2. Open the app, and pair when iOS asks. Release firmware requires bonding
   before it accepts any CAT traffic.
3. The connection screen should report the radio it detected. The app probes
   the baud rate and picks the CAT dialect itself.

If it connects but shows no data, the usual causes are baud (the app probes
38400 → 9600 → 4800, but the radio's menu must be set to one of them), or the
radio's CAT port being the wrong one of two on an FT-891.

**If HF noise rises when the bridge is powered**, the boost converter is the
suspect: fit a clip-on ferrite on the USB lead, and consider lining the lid
over the boost with copper tape bonded to battery negative.

---

## Where things live

```
BOM.md              what to buy, and where
enclosure/          case: STLs, OpenSCAD source, print + assembly detail
esp32s3/            firmware: build, test, flash, bench tools
ios/pocket-cat-*/   the iOS apps
docs/               design plans and reports
```
