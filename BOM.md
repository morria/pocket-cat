# PocketCAT — bill of materials

Quantities are per unit.

---

## Electronics

| Qty | Item | Key dimensions | Notes |
|---|---|---|---|
| 1 | Seeed XIAO ESP32S3 | 17.7 × 21.1 mm, USB-C overhangs 2.9 mm | No onboard antenna — the U.FL connector must be used |
| 1 | LiPo cell, 602535, 3.7 V 500 mAh | 25 × 37 × 6 mm | JST PH2.0 plug is cut off; leads solder to BAT+/BAT− |
| 1 | FPC antenna, 2.4 GHz | 37 × 18 mm | Ships with the XIAO. Mounts in the lid recess; pigtail is 1.13 mm coax |
| 1 | TPS61023 boost module | 17.8 × 11.3 mm | Adafruit MiniBoost clone. **Do not fit the pin header.** Any PCB thickness 0.6–1.8 mm is retained |
| **2** | Slide switch, SS12F15G5 | 19.8 × 5.6 × 13 mm | SPDT, 3-pin. S1 master, S2 mode. See below |

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

---|---|---|
| Frame length, lug to lug | 19.05 mm (0.750″) | `sw_frame_l` |
| Mounting hole ⌀ | 2.37 mm (3/32″) | `sw_hole_d` |
| Mounting hole pitch | 14.82 mm | derived |
| Actuator | 6.16 × 4.3 mm | `sw_act_l`, `sw_act_h` |
| Body | 11.39 × 5.8 mm | — |

This part is not identified by manufacturer part number and may be hard
to re-source. **SS12F15G5** is a catalogued alternative in the same
family and is a reasonable substitute, but it is not a drop-in: its frame
is 19.7–19.8 mm, its holes are ⌀2.2 mm, and its actuator is a 3 × 3 × 5
mm knob with 3.0 mm travel. Switching to it requires updating
`sw_frame_l`, `sw_hole_d`, `post_d`, `sw_act_l`, `sw_act_h` and
`sw_travel`, then reprinting the base. Its hole pitch is not published —
measure before regenerating.

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
| ~600 mm | 22 AWG silicone stranded, 2 colours | 9 runs at ~60 mm; twist each pair. 26 AWG also fine and easier to route |
| — | Hot glue | Strain relief over the BAT+/BAT− joints |
| — | Cyanoacrylate | Fixes the switch to its pegs |
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
