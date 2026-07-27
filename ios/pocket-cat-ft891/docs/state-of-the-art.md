# State of the Art: Mobile CAT Control Apps and BLE-to-CAT Bridges

Survey of existing mobile (especially iOS) amateur-radio rig-control applications, the
transports they use, the UI patterns they have converged on, and prior art for full-radio
configuration backup/restore — with emphasis on what applies to a Yaesu FT-891 iOS app
driven over a BLE serial bridge.

Researched July 2026.

---

## 1. iOS apps for rig control

### 1.1 The Roskosch family (DL8MRE) — the commercial benchmark

Marcus Roskosch (DL8MRE) is effectively the one-man state of the art for paid iOS rig
control. His apps share a common design language and are the ones to study most closely.

**SDR-Control for Icom** (iPad, ~$50; [App Store](https://apps.apple.com/us/app/sdr-control-for-icom/id1614141094))
- Radios: Icom IC-705, IC-7610, IC-9700, IC-R8600 — i.e. only Icoms with **built-in
  WiFi/Ethernet** speaking Icom's network protocol. No extra hardware or PC needed.
- Transport: WiFi/LAN direct to the radio (Icom's UDP-based network protocol), also
  usable remotely over the internet.
- Features: full mode control, dual VFO with waterfall, DualWatch audio, integrated FT8/FT4,
  CW keyer + decoder, SSTV, logbook with ADIF import/export, DX cluster with calls on a map.
- UI: panadapter/waterfall-centric, large frequency readout, on-screen tuning knob,
  slide-out panels for less-used controls.
- Strengths: it is a complete *operating environment*, not just a remote head — audio,
  digimodes, and logging in one app; excellent support and update cadence; reviewers call
  it a "game-changer".
- Weaknesses: expensive; Icom-network-radios only; iPad-oriented (the iPhone version is a
  separate app).

**SDR-Control Mobile** (iPhone counterpart; [App Store](https://apps.apple.com/us/app/sdr-control-mobile/id1673327509),
[manual](https://documents.roskosch.de/sdr-control-mobile/))
- Same Icom network transport, redesigned for a phone-size screen: fewer simultaneous
  panels, more paging/tabs, portrait-first. Native iOS 26 app, back-compatible to iOS 17.
- Demonstrates that a full transceiver UI (waterfall, FT8, CW keyer, logbook) *can* be made
  to work on an iPhone if the layout is rethought rather than shrunk.

**FT-Control for Yaesu** ([docs](https://documents.roskosch.de/ham-control-yaesu-ios/))
- The closest thing to "our app" that exists commercially for Yaesu.
- Radios: FT-710, FTDX-10, FTDX-101 only — because it depends on **Yaesu's SCU-LAN10
  network interface**. The FT-991 and portable rigs (FT-891 included) are explicitly *not*
  supported because they have no SCU-LAN path.
- Features: SSB via iPhone mic/AirPods, CW keyer + decoder, FT8/FT4, DX cluster, POTA
  tracking, PSK Reporter, SSTV/APRS/WeFAX, logbook with ADIF, MIDI/CTR2 controller support.
- UI: dual-VFO frequency display, waterfall, power/ALC meters, on-screen PTT, mode
  buttons; tap the VFO frequency to get a direct-entry keypad; supplemental tuning panels.
- Lesson: even the best iOS Yaesu app is gated entirely on transport availability. The
  FT-891 is orphaned by Yaesu's own ecosystem — which is exactly the gap a BLE bridge fills.

**SmartSDR for iOS (FlexRadio)** ($79.99; [App Store](https://apps.apple.com/us/app/smartsdr-flexradio-systems/id1089157289))
- Radios: FLEX-6000/8000 series over WiFi/SmartLink.
- Notable UI details worth stealing: graphical tuning knob, band/mode shown inside the
  panadapter, direct bandwidth buttons, instant memory creation, per-band stacking, voice
  macro record/playback, Bluetooth/USB hardware-knob controller support.
- Weakness: only one panadapter at a time vs. the Windows client; price.

### 1.2 Other iOS apps

- **PSKer** (KE7SCH; [site](https://ke7sch.net/psker/PSKer.html)) — PSK31/RTTY modem for
  iOS/macOS, first shipped 2012, fully rewritten in Swift in May 2026. Audio-coupled (mic/
  speaker), no CAT at all. Relevant mainly as proof that hobbyist iOS ham apps get orphaned
  and then need total rewrites — plan for longevity.
- **CommCat Mobile** ([eHam reviews](https://www.eham.net/reviews/view-product?id=9206)) —
  older free iPhone app doing frequency/mode/split/PTT + spots + logging, but only as a
  thin client to the CommCat Windows program acting as the rig server. Classic
  "PC-in-the-middle" architecture.
- **Ham Radio Deluxe / rigctld ecosystems** — no first-party iOS clients; a handful of
  small "CATweb"-style apps talk to a rigctld or web gateway on the LAN.
- **aRig** — could not be located on the App Store or the web; either discontinued or too
  obscure to matter. Not a factor.
- **HamCockpit** (VE3NEA; [site](https://ve3nea.github.io/HamCockpit/)) — sometimes
  mentioned in this space but it is a **Windows** plugin-based integrated environment
  (rig control, spectrum, spotting), MIT-licensed. Not mobile; interesting only for its
  modular architecture ideas.
- **Icom RS-BA1** ([Icom](https://www.icomamerica.com/lineup/options/RS-BA1_Version2/)) and
  **Kenwood ARCP-990** — the manufacturers' own remote-control offerings are
  **Windows-only**; neither Icom, Kenwood, nor Yaesu ships an iOS CAT app. The entire iOS
  space is third-party.

### 1.3 Android apps worth learning from

- **FT8CN** (BG7YOZ/N0BOY; [GitHub](https://github.com/N0BOY/FT8CN)) — free Android FT8 app
  with *built-in CAT for dozens of rigs* over USB-serial, Bluetooth (SPP and BLE — e.g.
  Xiegu X6100/X6200 built-in Bluetooth), and WiFi (Icom LAN protocol). Its open-source rig
  drivers (including Yaesu FT-891 CAT) are a useful protocol reference, and the Ham2K PoLo
  project has discussed reusing them. Lesson: on a platform without Apple's Bluetooth
  restrictions, apps happily talk straight to the radio; the app, not a PC, owns the CAT
  session.
- **Pocket RxTx** (Dan Toma YO3GGX; [site](https://www.yo3ggx.ro/), [Play Store
  Pro version](https://play.google.com/store/apps/details?id=ro.yo3ggx.rxtxpro)) —
  **Android-only** (despite occasional claims otherwise) multimode rig control: direct CAT
  over Bluetooth SPP or USB-serial (FT-817/857/897 natively), or network via HRD server /
  WebSDR. Controls mode, power, band, VFO A/B, PTT. UI is a skinnable virtual front panel
  with a round tuning knob. Lesson: supporting both "direct CAT" and "server" transports in
  one app is well precedented.
- **BlueCAT app + RepeaterBook apps** (ZBM2; [BlueCAT](https://www.zbm2.com/BlueCAT/)) —
  Android apps purpose-built around a Bluetooth CAT dongle, mostly for FT-8x7-era rigs.
  Simple frequency/mode push from a repeater directory. Lesson: even minimal
  "set frequency + mode from a list" control is genuinely useful in the field.

---

## 2. Transports: how apps reach the radio

| Transport | Works on stock iOS? | Who uses it |
|---|---|---|
| WiFi to network-native radio (Icom LAN, Flex, Yaesu SCU-LAN10) | Yes | SDR-Control, SmartSDR iOS, FT-Control |
| WiFi to a PC/Pi rig server (rigctld/hamlib, flrig, wfview, HRD, CommCat) | Yes | CommCat Mobile, misc. rigctld clients |
| USB serial (CP210x/FTDI cable to CAT port) | **No** (no user-accessible USB-serial stack; MFi only) | Android apps (FT8CN, Pocket RxTx via OTG) |
| Bluetooth Classic SPP | **No** without Apple MFi certification of the accessory | Android apps + HC-05/ESP32-SPP dongles, classic BlueCAT |
| **BLE (GATT serial bridge, e.g. Nordic UART Service)** | **Yes — CoreBluetooth, no MFi needed** | BlueCAT LE, ESP32 DIY bridges, Xiegu built-in BT |

Key facts:

- Apple restricts Bluetooth Classic profiles (incl. SPP) to MFi-certified accessories;
  **BLE via CoreBluetooth has no such restriction** ([Serialio explainer](https://serialio.com/faq/whats-the-difference-between-bluetooth-le-and-bluetooth-spp-ble-vs-spp/)).
  ZBM2 states it plainly for the classic BlueCAT: "Due to restrictions by Apple BlueCAT
  will NOT work with Apple iPhones or iPads" — hence their **BlueCAT LE** BLE variant
  aimed at iOS/Android.
- The de-facto BLE serial convention is the **Nordic UART Service (NUS)**, UUID
  `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` with RX (`...0002`) write and TX (`...0003`)
  notify characteristics. Off-the-shelf ESP32/nRF firmware and iOS terminal apps all speak
  it; supporting NUS makes an app compatible with cheap generic bridges.
- CAT is low-bandwidth (FT-891: 4800–38400 baud, short ASCII commands), which is exactly
  the workload BLE handles well. Audio is the thing BLE *cannot* carry — which is why the
  Roskosch apps use WiFi radios, and why a BLE-bridge app should scope itself to control +
  metering, not remote audio.
- Rig servers remain a legitimate second transport: **wfview**
  ([GitHub](https://github.com/wf-group/wfview)) now supports Icom, Kenwood *and Yaesu*
  and exposes a **rigctld-compatible TCP port** (default 4533); hamlib's `rigctld`
  protocol is the lingua franca a future "network mode" should speak.
- Dongle prior art: commercial CAT-Bluetooth adapters for FT-8x7
  ([passion-radio example](https://www.passion-radio.com/interface-cable/81T620-2228.html))
  power themselves from the CAT/ACC jack — no battery, no wall wart. An FT-891 bridge
  should do the same (the FT-891 CAT/GPS jacks and 13.8 V accessory line make this easy).
  ESP32 BLE-UART bridge firmware is a solved problem
  ([example 1](https://github.com/olegv142/esp32-bt-serial),
  [example 2](https://github.com/dr-stefan-krank/ESP32-S3-VCP-BT-Bridge/)).

**Bottom line:** for a stock-iOS app talking to an FT-891 — a radio with no network
interface and no MFi accessory — a **BLE-to-UART bridge on the CAT port is the standard
and essentially the only practical direct path.** Everything else requires a computer in
the shack.

---

## 3. State-of-the-art UI patterns for phone rig control

Observed across SDR-Control (Mobile), SmartSDR iOS, FT-Control, and the better Android
apps:

**Tuning interaction** — the hard problem; mature apps offer *all three* of:
1. **Rotary knob gesture** — a drawn tuning knob (SmartSDR's "graphical tuning knob",
   Pocket RxTx's skinned knob) or a horizontal fling-wheel; circular drag maps angle to
   ticks. Good for "spinning around" a band.
2. **Digit-wise tuning** — tap/swipe up-down on an individual digit of the frequency
   display to increment/decrement that decade; universally expected by hams because it
   mirrors desktop CAT software.
3. **Direct entry keypad** — tap the frequency readout to open a numeric pad (FT-Control
   does exactly this). Fastest for nets/spots.
   Plus a **step control** (10 Hz/100 Hz/1 kHz/…) and per-mode default steps.
4. **Haptics on detents** — `UIImpactFeedbackGenerator`/CoreHaptics ticks per tuning step
   make a glass knob feel mechanical; light tick per step, heavier tick on band edge or
   100 kHz boundary. (Apple's own Crown/picker idiom; increasingly present in newer apps.)

**Meters** — S-meter/PO/SWR/ALC drawn as fast-updating horizontal bargraphs or arc gauges
with peak-hold; FT-Control shows power/ALC alongside the VFO. Polling rate matters more
than rendering style: meters should update ~10 Hz while other state polls slower. Show
S-units + dB-over, not raw numbers.

**Mode & band selection** — a horizontal row/grid of mode buttons (LSB USB CW AM FM DATA)
and a **band bar** (160–6 m) rather than menus. Flex/Yaesu-style **band stacking
registers** (per-band last frequency/mode memory, 2–3 deep) are expected behavior when
tapping a band button repeatedly.

**Layout** — dark-mode-first (every serious radio app defaults dark; waterfall and night
operating demand it), giant frequency readout as the visual anchor, PTT (if any) as a
large deliberate control with lock/hold semantics, secondary settings behind swipe-up
sheets rather than nav stacks.

**Apple HIG specifics for this category:**
- SF Symbols for mode/band/meter iconography; monospaced-digit system font
  (`.monospacedDigit()`) for the frequency readout so digits don't jiggle while tuning.
- Dynamic Type for labels (the ham demographic skews older — legibility is a feature);
  meters and frequency display can be fixed-size, but respect accessibility contrast.
- VoiceOver labels for frequency/mode state; `.adjustable` accessibility trait on the
  tuning control (swipe up/down to tune) is the correct HIG pattern for a knob.
- Support both orientations on iPhone reluctantly — portrait-first with a purpose-built
  landscape "operating" layout is what SDR-Control Mobile does.
- Persist connection state and reconnect automatically; CoreBluetooth state restoration
  lets the app resume a BLE session in the background.

---

## 4. Configuration save/restore precedents

### FTRestore (VK2BYI) — the direct precedent, FT-891 included

[FTRestore](https://www.vk2byi.com.au/ftrestore/) (Chris Fredericks, VK2BYI; freeware,
Windows) uploads, downloads, and **compares memory channels and menu settings** for the
FTDX1200, FTDX3000, FTDX5000, **FT-891**, and FT-991/991A — entirely **over CAT** (no
clone mode). Workflow: read radio → grid editor → save to **Excel-compatible (.xlsx)
file** → later re-download to the radio; a compare function diffs a saved file against
the live radio before writing. Handles regular and PMS memory channels plus the full menu
tree, and can import CSVs exported by other programmers.
([Manual PDF](https://dk0erf.de/data/documents/FTRestore-1.1.0.pdf),
[support group](https://groups.io/g/vk2byi-ftrestore))

Lessons:
- The FT-891's **entire menu system is readable and writable via CAT `EX` commands** —
  FTRestore proves the mechanism our app needs already works on this exact radio.
- "Read → show as editable table → diff against radio → selective write" is the right
  UX shape; a blind bulk-restore is scary, a visible diff is trustworthy.
- Last release 2021, Windows-only, .NET — the niche is effectively abandoned and has
  **no mobile equivalent at all**.

### Others

- **Win4Yaesu Suite** (VA2FSQ; [site](https://yaesu.va2fsq.com/)) — paid Windows control
  suite for FTDX-10/101/1200/3000/5000/9000 + FT-991A (**not** FT-891). Exposes hidden
  menu items as point-and-click controls and can **export/import all menu settings to a
  file** — mainly pitched as surviving firmware updates that wipe settings. Same
  motivation applies verbatim to the FT-891.
- **RT Systems ADMS-891** ([product](https://www.rtsystemsinc.com/FT-891_c_810.html)) —
  paid Windows/macOS programmer for the FT-891: spreadsheet grid of memory channels plus
  "other radio menu items", copy/paste and column editing, imports from RepeaterBook/
  RadioReference/Travel Plus. Uses its own proprietary file format tied to their RT-42
  cable. Lesson: repeater-directory import and column-edit ergonomics are valued;
  proprietary lock-in is the chief complaint.
- **CHIRP** ([chirpmyradio.com](https://chirpmyradio.com)) — the open-source standard for
  memory programming, with clone-mode drivers for FT-817/857/897 etc.; **no FT-891
  support** (community threads point people to RT Systems instead). CHIRP's `.img` +
  CSV-interchange model and its per-radio driver structure are still the reference for
  open config formats.

Format takeaway: prior art uses spreadsheet-shaped files (xlsx, CSV, proprietary). For a
modern app, a **versioned JSON document** (radio model, firmware, timestamp, keyed menu
values + memory list) with CSV export for interchange is strictly better, and diff-able.

---

## 5. FT-891-specific landscape

- The FT-891 has **no LAN/WiFi/Bluetooth** and no SCU-LAN option; its rear **USB port**
  (SiLabs dual-UART: Enhanced = CAT, Standard = PTT/keying lines) and **CAT jack** are
  the only control paths. Yaesu's own free ADMS programmer and RT Systems cover memory
  programming; **nothing covers live control from a phone.**
- CAT protocol: FTDX-family ASCII command set (semicolon-terminated, `FA…;` `MD…;`
  `EX…;` etc.), 4800–38400 baud. Menu items are addressed by number via `EX`; FTRestore
  demonstrates full menu + memory coverage over this interface on the FT-891
  specifically.
- Known ecosystem grumbles to design around: the radio's tiny screen and deep 150+-item
  menu tree (the community maintains menu spreadsheets —
  [groups.io thread](https://groups.io/g/FT-891/topic/87452805)); settings loss on
  firmware update/reset; digital-modes setup requiring a dozen scattered menu changes
  ([TheModernHam guide](https://themodernham.com/ft-891-the-ultimate-digital-settings-menu-guide-for-digital-modes/)).
- No off-the-shelf BLE bridge is marketed for the FT-891 the way BlueCAT is for the
  FT-8x7, but the ingredients are commodity: ESP32/nRF + level shifting on the CAT jack,
  NUS firmware, powered from the rig.

---

## 6. Implications for our app

1. **BLE bridge is the right and only direct transport.** Speak Nordic UART Service so
   generic ESP32/nRF dongles and DIY bridges work out of the box; keep the protocol layer
   transport-agnostic so a TCP mode (rigctld/wfview server) can be added later for
   shack-PC users.
2. **We are filling a real gap.** Roskosch's FT-Control explicitly cannot support the
   FT-891 (no SCU-LAN); FTRestore is Windows-only and dormant; there is no phone-native
   FT-891 controller anywhere. The FT-891's portable/POTA audience is exactly the
   audience holding a phone.
3. **Scope to control + metering, not audio.** BLE can't carry audio; don't try. The
   winning phone apps that do audio all ride manufacturer WiFi stacks we don't have.
4. **Copy the converged tuning UX:** big monospaced frequency readout; digit-wise
   tap/swipe tuning; tap-to-open direct-entry keypad; a knob/wheel gesture with
   selectable step; haptic detents per step. Band bar with band-stacking registers; mode
   buttons, not menus.
5. **Meters need a fast poll loop** (~10 Hz for S/PO/SWR/ALC with peak-hold) decoupled
   from slower state polling; render as bargraphs with S-unit scale.
6. **Dark-mode-first, HIG-native:** SF Symbols, monospaced digits, Dynamic Type,
   VoiceOver `.adjustable` tuning control, CoreBluetooth state restoration for seamless
   reconnect.
7. **Make config backup/restore a headline feature, modeled on FTRestore:** read all
   `EX` menu settings + memories over CAT, store as versioned JSON (with CSV export),
   show a **diff against the live radio** before selective restore. Named profiles
   ("SSB field", "FT8", "CW contest") directly answer the FT-891 community's biggest
   pain point (menu-diving for digital modes, settings lost on firmware
   updates/resets) — and nothing on any platform offers profile *switching* today.
8. **Plan for longevity:** the graveyard (PSKer's decade of dormancy, FTRestore, CommCat
   Mobile) shows hobbyist iOS ham apps die of platform churn. Modern Swift/SwiftUI,
   minimal dependencies, and an open protocol/driver layer (FT8CN's open-source Yaesu
   drivers are a reference) hedge against that.

---

### Sources

- SDR-Control for Icom — https://apps.apple.com/us/app/sdr-control-for-icom/id1614141094
- SDR-Control Mobile — https://apps.apple.com/us/app/sdr-control-mobile/id1673327509 / https://documents.roskosch.de/sdr-control-mobile/
- FT-Control for Yaesu — https://documents.roskosch.de/ham-control-yaesu-ios/
- SmartSDR for iOS — https://apps.apple.com/us/app/smartsdr-flexradio-systems/id1089157289
- PSKer — https://ke7sch.net/psker/PSKer.html
- CommCat Mobile — https://www.eham.net/reviews/view-product?id=9206
- FT8CN — https://github.com/N0BOY/FT8CN
- Pocket RxTx — https://www.yo3ggx.ro/ / https://play.google.com/store/apps/details?id=ro.yo3ggx.rxtxpro
- BlueCAT (ZBM2) — https://www.zbm2.com/BlueCAT/
- BLE vs SPP / MFi — https://serialio.com/faq/whats-the-difference-between-bluetooth-le-and-bluetooth-spp-ble-vs-spp/
- wfview — https://github.com/wf-group/wfview / https://wfview.org/wfview-user-manual/hamlib-rigctld-emulation/
- ESP32 BLE-serial bridges — https://github.com/olegv142/esp32-bt-serial / https://github.com/dr-stefan-krank/ESP32-S3-VCP-BT-Bridge/
- FTRestore — https://www.vk2byi.com.au/ftrestore/ / https://dk0erf.de/data/documents/FTRestore-1.1.0.pdf
- Win4Yaesu Suite — https://yaesu.va2fsq.com/
- RT Systems ADMS-891 — https://www.rtsystemsinc.com/FT-891_c_810.html
- CHIRP — https://chirpmyradio.com
- Icom RS-BA1 — https://www.icomamerica.com/lineup/options/RS-BA1_Version2/
- HamCockpit (VE3NEA) — https://ve3nea.github.io/HamCockpit/
- FT-891 community menu/digital-settings resources — https://groups.io/g/FT-891/topic/87452805 / https://themodernham.com/ft-891-the-ultimate-digital-settings-menu-guide-for-digital-modes/
