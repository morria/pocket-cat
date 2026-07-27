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

```sh
swift test                       # QMXKit + sim-driven integration
cd App && xcodegen generate      # then open QMX.xcodeproj
```

The connection sheet includes a **Simulated QMX** — the entire app runs
against the built-in simulator with no hardware.
