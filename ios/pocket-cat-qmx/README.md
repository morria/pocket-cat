# Pocket Cat QMX

An iOS rig controller for the **QRP Labs QMX** through a Pocket Cat
bridge: frequency, the QMX's four modes plus sideband, RIT, split, keyer
speed, live meters — and **the radio's entire configuration menu**,
discovered live over the QMX's `MM`/`ML` Menu Manager CAT commands, with
a written explanation for every item the catalog knows.

Because discovery is live, the menu screen always matches the connected
firmware: items this app has never heard of still appear and edit
correctly (with a generic note) — `QMXMenuNotes` just hasn't written them
up yet.

Profiles capture **everything** — every menu leaf (including per-band
grid cells) plus operating state — into a `.qmxjson` file in iCloud
Drive, and apply writes back only what differs, with per-item read-back
verification. QMX `MM` writes persist to the radio's EEPROM.

Layout mirrors `../pocket-cat-ft891`:

```
Sources/QMXKit/     RigController, QMX command wrappers (Q1/RIT/SP/meters),
                    MM/ML menu client + explanations, profiles, simulator
Sources/QMXUI/      SwiftUI: Operate / Menu / Profiles
App/                xcodegen shell (cd App && xcodegen generate)
Tests/QMXKitTests/  swift-testing: protocol units + sim-driven integration
```

Wire formats follow the *QMX CAT programming manual* fw 1_02_006
(`esp32s3/docs/references/qmx-cat.md`). Notable QMX facts the app
respects: `PC` is a **get-only power meter in tenths of a watt**, `SM`
reads dB, `MD` accepts only CW/DIGI/CW-R/FSK-R (sideband is `Q1`), and
the two-letter commands are session-only while `MM` writes persist.

## Prerequisites

Xcode 15+, and `xcodegen` (`brew install xcodegen`). The package depends on
the root Pocket Cat package (`CATBridgeKit`) by the relative path `../..`, so
a plain checkout is all you need.

## Test

```sh
swift test          # QMXKit + sim-driven integration, no hardware
```

## Build and run

```sh
cd App && xcodegen generate      # creates QMX.xcodeproj
open QMX.xcodeproj               # run the QMXApp scheme
```

The connection sheet includes a **Simulated QMX** — the entire app runs
against the built-in simulator with no hardware. Start there.

**`App/project.yml` has a `DEVELOPMENT_TEAM` baked in — replace it with
yours**, or device builds will fail to sign. Find your team ID with:

```sh
security find-certificate -c "Apple Development" -p |
  openssl x509 -noout -subject | tr ',' '\n' | grep OU
```

## Install on a device

```sh
xcrun devicectl list devices          # find the device identifier
xcodebuild build -project QMX.xcodeproj -scheme QMXApp \
  -destination 'id=YOUR-DEVICE-ID' -derivedDataPath build \
  -allowProvisioningUpdates
xcrun devicectl device install app --device YOUR-DEVICE-ID \
  build/Build/Products/Debug-iphoneos/QMXApp.app
```

The device must be unlocked with Developer Mode enabled.
`-allowProvisioningUpdates` also registers the app's iCloud container the
first time, which profile sync needs. If signing still fails on the iCloud
entitlement, add the capability in Xcode (target → Signing & Capabilities →
**+ Capability** → iCloud) — or strip it as the FT-891 app does with its
`FT891App-NoCloud.entitlements`, at the cost of falling back to on-device
profile storage.
