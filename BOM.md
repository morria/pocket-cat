# PocketCAT — bill of materials

Quantities are per unit. Where to buy each item is in
[Where to buy](#where-to-buy) below; the tools you need but don't consume
are in [Tools](#tools--needed-to-build-not-part-of-the-unit).

For the build itself, start at [`BUILD.md`](BUILD.md).

---

## Electronics

| Qty | Item | Key dimensions | Notes |
|---|---|---|---|
| 1 | Seeed XIAO ESP32S3 | 17.7 × 21.1 mm, USB-C overhangs 2.9 mm | No onboard antenna — the U.FL connector must be used |
| 1 | LiPo cell, 602535, 3.7 V 500 mAh | 25 × 37 × 6 mm | JST PH2.0 plug is cut off; leads solder to BAT+/BAT− |
| 1 | FPC antenna, 2.4 GHz | 37 × 18 mm | Ships with the XIAO, U.FL pigtail |
| 1 | TPS61023 boost module | 17.8 × 11.3 mm | Adafruit MiniBoost clone. **Do not fit the pin header** |
| 1 | Slide switch, SS12F15G5 | 19.8 × 5.6 × 13 mm | SPDT, 3-pin. See below |

### Slide switch — SS12F15G5

| Parameter | Value | `.scad` parameter |
|---|---|---|
| Frame length, lug to lug | 19.8 mm | `sw_frame_l` |
| Mounting hole ⌀ | 2.2 mm | `sw_hole_d` |
| Mounting hole pitch | 14.4 mm nominal | `sw_pitch_spec` |
| Knob | 3.0 × 3.0 × 5.0 mm | `sw_act_l`, `sw_act_h` |
| Travel | 3.0 mm assumed | `sw_travel` |
| Body | 10.0 × 5.6 × 5.0 mm | — |

Sold in the same G5 variant by many suppliers, so the BOM is repeatable.

Two figures are not published by any seller and were scaled off the
manufacturer drawing: the **hole pitch** and the **travel**. The mount
does not depend on the pitch being right — see the peg pair in the README
— but if the knob binds at the ends of its throw, measure the travel and
reduce `sw_travel`.

### Substituting a different slide switch

The base is dimensioned for the SS12F15G5 above. Any other SPDT slide
switch is a reprint, not a drop-in: measure yours, update `sw_frame_l`,
`sw_hole_d`, `post_d`, `sw_act_l`, `sw_act_h` and `sw_travel` in
`enclosure/pocket_cat_case.scad`, and regenerate the base.

An earlier prototype used an unbranded imperial switch — 19.05 mm
(0.750″) frame, ⌀2.37 mm (3/32″) holes, 6.16 × 4.3 mm actuator — which is
recorded here only so an old printed base can be identified. Do not buy
it; it has no manufacturer part number and cannot be re-sourced
reliably.

---

## Hardware

| Qty | Item | Notes |
|---|---|---|
| 1 | M3 × 10 hex socket head cap screw | M3 × 12 also fits |
| 1 | M3 nut, standard | 5.5 mm across flats, 2.4 mm thick |

No washer — the head seats in a counterbore inside the base.

---

## Printed parts

| Qty | File | Material | Solid volume | Mass |
|---|---|---|---|---|
| 1 | `pocket_cat_base.stl` | PETG | 11.05 cm³ | ~14 g |
| 1 | `pocket_cat_lid.stl` | PETG | 10.25 cm³ | ~13 g |

Roughly **23 g** of PETG per unit at 4 walls and 25 % infill, about 7.5 m
of 1.75 mm filament. No supports.

---

## Wire and consumables

| Qty | Item | Notes |
|---|---|---|
| ~500 mm | 26 AWG stranded hookup wire, 2 colours | 7 runs at ~60 mm; twist each pair |
| — | Hot glue | Strain relief over the BAT+/BAT− joints |
| — | Foam tape or cyanoacrylate | Fixes the boost module and the switch |
| — | Isopropyl alcohol | Prep the antenna bay floor before adhering |
| — | Kapton tape | Optional, only if the cell rattles |

---

## Interface

| Qty | Item | Notes |
|---|---|---|
| 1 | USB-C cable to the radio | Type and length depend on the transceiver's CAT port |

---

## Optional — RF mitigation

| Qty | Item | Notes |
|---|---|---|
| 1 | Clip-on ferrite for the USB lead | Against boost switching noise on HF |
| — | Copper foil tape | Line the lid over the boost, bond to battery negative |

---

## Tools — needed to build, not part of the unit

| Qty | Item | Notes |
|---|---|---|
| 1 | **USB-to-UART dongle, 3.3 V logic** | CP2102, CH340 or FT232. **Required to flash.** The XIAO's own USB-C port is used for the radio, so console and bootloader live on UART0 |
| 1 | Temperature-controlled soldering iron, fine tip | The BAT pads are small and lift under heat |
| 1 | Multimeter | To verify cell polarity and the boost output before connecting either |
| 1 | Side cutters, wire strippers, tweezers | 26 AWG |
| 1 | 2.5 mm hex key | For the M3 cap screw |
| 1 | Hot glue gun, hobby knife | Strain relief; dressing the printed switch pegs |

Buy a dongle with **3.3 V logic levels**. A 5 V-only dongle will damage
the board.

---

## Where to buy

No links or prices here — they rot. Vendor and exact part name, so a
search finds the right thing.

| Item | Where | Search for | Check on arrival |
|---|---|---|---|
| XIAO ESP32S3 | Seeed Studio direct; also Mouser, DigiKey, Amazon | "XIAO ESP32S3" | The **plain** board, not "Sense". Confirm the **U.FL connector** is present and the FPC antenna is in the box |
| 602535 LiPo cell | Battery and hobby suppliers, AliExpress, Amazon | "602535 3.7V 500mAh JST PH2.0" | **Measure thickness — must be ≤ 6 mm.** Verify polarity with a meter; cheap cells are not consistent about which JST pin is positive |
| TPS61023 boost | Adafruit, as "MiniBoost 5V @ 1A — TPS61023"; clones on AliExpress | "TPS61023 boost module" | Board no larger than 17.8 × 11.3 mm. Leave the pin header unsoldered |
| SS12F15G5 switch | AliExpress, LCSC, eBay | "SS12F15G5" | Usually sold in packs of 10+. 19.8 mm frame, ⌀2.2 mm holes |
| M3 bolt + nut | Any fastener assortment | "M3 socket head cap screw 10 mm" | Hex socket, not Phillips — the counterbore is sized for a cap head |
| 26 AWG wire | Amazon, AliExpress | "26 AWG silicone stranded wire" | Silicone insulation is far easier to dress in a tight case than PVC |
| USB-UART dongle | Amazon, AliExpress, Adafruit | "CP2102 USB to TTL 3.3V" | Must support **3.3 V** logic |
| Clip-on ferrite | Amazon, electronics suppliers | "clip-on ferrite core 5 mm" | Only if the boost raises your noise floor |

The cell and the switch are the long-lead items if ordered from
overseas. Order them first and print the case while you wait.

**Cells cannot be shipped by air by most sellers**, so a domestic
supplier is usually faster even when it costs more.

---

## Wiring summary

| From | To |
|---|---|
| Cell + | Switch common |
| Switch output | XIAO BAT+ |
| Switch output | Boost Vin |
| Cell − | XIAO BAT− |
| Cell − | Boost GND |
| Boost 5V | XIAO VUSB |
| Boost GND | XIAO GND |

The switch sits upstream of both loads, so switching off also kills the
boost. That prevents the boost output back-feeding a host's VBUS when a
PC is plugged into the USB-C port to reflash.

Check whether En has a pull-up on your boost module. If not, tie it
to Vin.
