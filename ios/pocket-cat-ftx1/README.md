# Pocket Cat FTX-1

Native iOS control for the Yaesu FTX-1 over the [Pocket Cat](../..) BLE↔USB
CAT bridge. SwiftUI, iOS 17+.

- **Operate** — frequency (digit-drag tuning, direct entry), full mode set,
  band bar with band-stacking, S/PO/SWR/ALC meters, RF power, antenna-tuner
  cycle, split/clarifier/VFO ops, the passband strip, hold-to-talk PTT
  (failsafe-interlocked).
- **CW** — type and the radio's memory keyer sends it, with station
  templates and an on-air time estimate.
- **Menu** — raw `EX` access by number, with bookmarks you build yourself.
- **Memories** — saved channels and automatic recents, kept on the device.

A built-in simulator (Connection → Simulated FTX-1) runs the whole app with
no hardware.

Built from the [FT-891 app](../pocket-cat-ft891): the FTX-1 speaks the same
modern Yaesu ASCII dialect, so the operate surface, passband strip, band
memories and connection plumbing carry straight over
(`esp32s3/docs/references/yaesu-cat-ftx1.md`).

## What differs from the FT-891 app

- **Full mode set.** The FTX-1 is a full-mode SDR, so the newcat codes the
  FT-891 leaves unused are live: `A` DATA-FM, `E` C4FM, `F` DATA-FM-N.
- **CW keyboard.** Send-only, and the screen says so — a Yaesu has no
  command that hands decoded CW back, which is why the QMX app has a live
  transcript and this doesn't.
- **Menu by number, not by catalog.** The FT-891 app ships a typed catalog
  of its 159 items. The FTX-1's numbering differs and this repo has no
  verified catalog for it, so the Menu tab reads and writes raw `EX` digits
  and lets the radio judge them. A borrowed catalog would confidently write
  the wrong setting.
- **No profiles yet.** Capture/diff/apply is built on that catalog, so it
  returns when there is one.

## Layout

```
Package.swift        FTX1Kit (radio semantics) + FTX1UI (SwiftUI)
Sources/FTX1Kit/     command wrappers, passband, band memories, CW text and
                     timing, station settings, simulator, RigController
Sources/FTX1UI/      Operate / CW / Menu / Connection views
App/                 xcodegen shell (project.yml) for the iOS app target
Tests/FTX1KitTests/  sim-driven integration, passband, memories
```

## Prerequisites

Xcode 15+, and `xcodegen` (`brew install xcodegen`) to generate the app
project. Nothing else to clone: this package lives inside the Pocket Cat
repo at `ios/pocket-cat-ftx1` and depends on the root package
(`CATBridgeKit`) by the relative path `../..`.

## Test

```sh
swift test          # headless: FTX1Kit + full sim integration, no hardware
```

## Build and run

```sh
cd App && xcodegen generate      # creates FTX1.xcodeproj
open FTX1.xcodeproj              # run the FTX1App scheme
```

Set your own signing team in Xcode (target → Signing & Capabilities); find
the ID with:

```sh
security find-certificate -c "Apple Development" -p |
  openssl x509 -noout -subject | tr ',' '\n' | grep OU
```

## Install on a device

```sh
xcrun devicectl list devices
xcodebuild build -project FTX1.xcodeproj -scheme FTX1App \
  -destination 'id=YOUR-DEVICE-ID' -derivedDataPath build \
  -allowProvisioningUpdates
xcrun devicectl device install app --device YOUR-DEVICE-ID \
  build/Build/Products/Debug-iphoneos/FTX1App.app
```

If signing fails on the iCloud entitlement, build with
`CODE_SIGN_ENTITLEMENTS=FTX1App/FTX1App-NoCloud.entitlements`.

## Not yet confirmed on hardware

The FTX-1 has not been through bring-up. Per
`esp32s3/docs/references/yaesu-cat-ftx1.md` its USB descriptor **is**
confirmed — a CP2105 behind an internal hub — but its `ID;` response code is
not, and neither is which of the dual UARTs is Enhanced. The app works
through the bridge's generic Yaesu profile regardless.

The passband strip's `IS`/`SH`/`BP`/`CO` formats are inherited from the
FT-891 family rather than verified on an FTX-1, and the simulator answers
`ID;` with the FT-891's code as a placeholder. Both want checking against a
real rig before they are trusted.
