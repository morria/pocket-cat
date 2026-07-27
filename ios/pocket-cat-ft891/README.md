# FT-891 Pocket

Native iOS control for the Yaesu FT-891 over the
[Pocket Cat](../..) BLE↔USB CAT bridge. SwiftUI, iOS 17+.

- **Operate** — frequency (digit-drag tuning, direct entry), mode, band,
  S/PO/SWR/ALC meters, RF power, antenna-tuner cycle, split/clarifier/VFO
  ops, hold-to-talk PTT (failsafe-interlocked).
- **Settings** — all 159 FT-891 menu items with plain-English names and
  descriptions, searchable, editable over CAT (`EX`).
- **Profiles** — capture the radio's full configuration to a JSON file in
  iCloud Drive; diff any profile against the live radio and apply the
  changes with per-item confirmation.

A built-in FT-891 simulator (Connection → Simulated FT-891) runs the whole
app with no hardware.

## Layout

```
Package.swift        FT891Kit (radio semantics) + FT891UI (SwiftUI)
Sources/FT891Kit/    menu catalog (159 items), FT-891 command wrappers,
                     profile engine/store, simulator transport, RigController
Sources/FT891UI/     Operate / Settings / Profiles / Connection views
App/                 xcodegen shell (project.yml) for the iOS app target
Tests/               codecs, catalog↔docs checker, sim-driven integration
docs/                CAT + menu references, research, fun-feature backlog
PLAN.md              design/implementation/test plan
```

## Prerequisites

Xcode 15+, and `xcodegen` (`brew install xcodegen`) to generate the app
project. Nothing else to clone: this package lives inside the Pocket Cat
repo at `ios/pocket-cat-ft891` and depends on the root package
(`CATBridgeKit`) by the relative path `../..`.

## Test

```sh
swift test          # headless: FT891Kit + full sim integration, no hardware
```

## Build and run

```sh
cd App && xcodegen generate      # creates FT891.xcodeproj
open FT891.xcodeproj             # run the FT891App scheme
```

Regenerate whenever `project.yml` changes; the `.xcodeproj` is not tracked.

Set your signing team in Xcode (target → Signing & Capabilities). Find your
team ID with:

```sh
security find-certificate -c "Apple Development" -p |
  openssl x509 -noout -subject | tr ',' '\n' | grep OU
```

Run the **Simulated FT-891** connection first — the entire app works against
the built-in simulator with no bridge and no radio.

## Install on a device

From Xcode: select your iPhone and run. From the command line:

```sh
xcrun devicectl list devices          # find the device identifier
xcodebuild build -project FT891.xcodeproj -scheme FT891App \
  -destination 'id=YOUR-DEVICE-ID' -derivedDataPath build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOURTEAMID
xcrun devicectl device install app --device YOUR-DEVICE-ID \
  build/Build/Products/Debug-iphoneos/FT891App.app
```

The device must be unlocked and have Developer Mode enabled.

**If signing fails on the iCloud entitlement** — *"provisioning profile
doesn't match the entitlements file's values for
`com.apple.developer.ubiquity-container-identifiers`"* — your team has no
iCloud container for this bundle ID. Either create one (Xcode → target →
Signing & Capabilities → **+ Capability** → iCloud), or build without it:

```sh
CODE_SIGN_ENTITLEMENTS=FT891App/FT891App-NoCloud.entitlements
```

Profiles then save on-device instead of to iCloud Drive; everything else is
unaffected.
