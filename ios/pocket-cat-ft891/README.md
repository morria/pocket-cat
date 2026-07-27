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

## Building

```sh
swift test                       # headless: FT891Kit + full sim integration
cd App && xcodegen generate      # create FT891.xcodeproj (needs xcodegen)
open FT891.xcodeproj             # run the FT891App scheme
```

This package lives inside the Pocket Cat repo at `ios/pocket-cat-ft891`
and depends on the root package (`CATBridgeKit`) by the relative path
`../..`, so it builds from a plain checkout with nothing else to clone.

iCloud profile sync needs the iCloud capability signed with your team;
without it the app falls back to on-device storage.
