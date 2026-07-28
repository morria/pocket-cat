# PocketCAT — enclosure

A two-part printed enclosure for a battery-powered Bluetooth-to-CAT
adapter. It holds a Seeed XIAO ESP32S3, a 602535 LiPo cell, a flat FPC
antenna, a slide switch, and a TPS61023 boost module that supplies 5 V to
the USB device attached to the XIAO.

**Closed size: 59.2 × 47.2 × 18.9 mm.** Two printed parts, one bolt, one
nut.

---

## Files

| File | Description |
|---|---|
| `pocket_cat_base.stl` | Base — cell bay, antenna bay, switch mount, bolt boss |
| `pocket_cat_lid.stl` | Lid — board pocket, boost cradle, captive nut boss |
| `pocket_cat_case.scad` | Parametric source, OpenSCAD customizer ready |
| `BOM.md` | Bill of materials |
| `WIRING.md` | Wiring diagrams and connection tables |

The `.scad` is the source of truth; both STLs are generated from it:

```
openscad -o pocket_cat_base.stl -D 'part="base"' pocket_cat_case.scad
openscad -o pocket_cat_lid.stl  -D 'part="lid"'  pocket_cat_case.scad
```

---

## Bill of materials

| Item | Notes |
|---|---|
| Seeed XIAO ESP32S3 | 17.7 × 21.1 mm, USB-C overhanging 2.9 mm |
| 602535 LiPo, 3.7 V 500 mAh | 25 × 37 × 6 mm pouch cell |
| FPC antenna, 37 × 18 mm | With U.FL pigtail |
| SS12F15G5 slide switch | SPDT, 19.8 mm frame, ⌀2.2 holes, 3 × 3 × 5 mm knob |
| TPS61023 boost module | 17.8 × 11.3 mm, header **not** fitted |
| M3 × 10 hex socket head bolt | ×1 |
| M3 nut | ×1 |
| 26 AWG stranded wire | ~60 mm per run |

---

## Layout

The interior is divided lengthwise by a 7 mm rib. Heavy items sit in the
base; the two circuit boards mount to the lid and lift out with it.

**Base, left bay — 27 × 39 × 7.0 mm.** The cell lies flat on the floor
against a backstop rib at the far end. There is 1.0 mm of clearance above
it for pouch swelling; nothing should be packed into that space.

**Base, right bay — 22 × 39 mm.** Empty apart from the slide switch on
its outer wall. The width is set by the span the lid needs for the
antenna, not by anything in the base.

**Base, right wall.** Two slide switches, centred at y 12.6 and y 34.6.
Each has its own peg pair on 14.4 mm centres and a 6.4 × 3.6 mm actuator
slot. S1 is the master on/off; S2 selects run or charge. A local 1.2 mm relief
in the lid skirt above the switch gives the frame room.

The pegs are deliberately unequal. One is round at ⌀1.90; the other is a
lozenge, 2.00 mm across the pitch axis but only 0.90 mm along it. The
round peg locates the switch and the lozenge holds its angle while
letting hole-spacing error float out. Together they absorb **±0.80 mm**
of pitch variation, against the ±5 % (±0.72 mm) these switches are made
to. Both taper at the tip for a square start and have 0.15 mm shaved off
their undersides to compensate for print sag.

**Divider rib.** Carries the bolt boss, and has a notch through its top
edge at each switch centreline, y 12.6 and y 34.6, for the switch
wiring.

**Lid, board pocket — 18.0 × 21.4 mm.** The XIAO sits component-side
down, USB-C pointing into the wall aperture. Two ramped tabs per side
retain it. The whole pocket floor is relieved 1.2 mm, giving 2.8 mm of
clearance over the BAT+/BAT− solder joints.

**Lid, wire channel.** A 3.0 mm gap through both pocket ribs at
y 12.6–15.6, with a matching groove in the lid, forms a 2.6 mm tall route
for the battery leads to leave the board pocket. Cut on both sides — use
whichever suits your pad positions.

**Lid, boost cradle — 18.8 × 12.3 mm.** Ribs 1.6 × 2.5 mm locate the
module on all four sides, with a 10 mm opening in the pad edge for
soldering access and a 0.5 mm lead-in chamfer at the mouth. The ribs are
a deliberately loose fit — 0.5 mm per side — so the module drops in
squarely. The bay clears modules up to 7.5 mm thick.

A compliant retention finger at each end snaps the module down. Each is
1.0 mm thick, hangs 4.2 mm below the lid and sits in its own relief slot
so it flexes independently. They stand at the board's nominal edge rather
than at the rib, so clearance and grip are set separately: the ribs stay
loose for easy insertion while the fingers alone do the holding.

The retaining face is a **wedge rather than a square shoulder**, so it
grips any PCB from 0.6 to 1.8 mm thick without knowing the thickness in
advance. Overlap onto the board is 0.21 mm at 1.0 mm thickness, 0.39 at
1.2 and 0.76 at 1.6. The finger's spring preloads the module against the
lid.

**Lid, boost-to-board channels.** Two 3.5 mm openings through the pocket
end stop at x 10.6–14.1 and 16.1–19.6, separated by a 2 mm web. They cut
below the board only (z 10.7–13.3), so the stop stays solid at board
level and still blocks the PCB's rear edge. These carry the boost 5V and
GND leads into the pocket; the web keeps the pair separated.

The battery-to-boost run needs no channel — the space between the cell
top and the lid is open the whole way, and the leads rise straight into
the cradle's 10 mm pad-edge gap.

**Lid, antenna recess — 18.4 × 37.4 × 0.4 deep.** The FPC adheres to the
lid inner face, in a shallow recess between the nut boss and the skirt.
Mounting it here rather than in the base keeps the whole RF path on one
part: the pigtail never crosses the parting line, so opening the case
does not flex the U.FL connector. It also puts the switch frame 7 mm
below the antenna instead of 1.1 mm above it.

**Lid, pigtail exit.** A full-height gap through both pocket ribs at
y 20.9–23.5, at the far end of the board from the USB-C. It runs below
the board only, so the lid keeps full thickness there. Two ⌀1.8 guide
posts at x 34.0 form a 1.6 mm channel carrying the pigtail past the nut
boss on its way to the antenna.

**Lid, wire anchors.** Two ⌀2.0 posts hanging 4.0 mm from the lid form a
**3.6 mm channel**, set 0.65 mm clear of the board pocket rib, sized for two 22 AWG silicone leads side by side.
They take strain off the BAT+/BAT− pads, which are surface pads with no
through-hole anchorage and lift if a lead is pulled.

---

## Fastener

A single M3 enters from the **underside**, its head fully recessed in a
⌀6.2 × 3.0 counterbore flush with the bottom face. It passes up through a
stub on the divider rib and threads into a nut held captive in a boss
under the lid. Nothing protrudes from either outer face.

The nut pocket sits at z 10.6–13.1 with 3.0 mm of material above it and
loads through a slot on the antenna-bay side. An M3 × 10 engages 2.4 mm
of thread; an M3 × 12 also fits.

Tighten snug only. The skirt engages 7.5 mm around the full perimeter and
carries the shear; the bolt only resists lift.

---

## Key dimensions

| Feature | Value |
|---|---|
| Cell bay | 27 × 39 × 7.0 mm |
| Antenna recess (lid) | 18.4 × 37.4 × 0.4 deep |
| Board pocket | 18.0 × 21.4 mm |
| Clearance over BAT pads | 2.8 mm |
| USB-C aperture | 9.6 × 3.8 mm, at z 9.8–13.6 |
| Switch slot | 6.42 × 3.62 mm |
| Panel markings | 3.5 mm tall (triangle 4.4), 0.9 stroke, 0.5 deep |
| Wire anchor channel | 3.6 mm wide × 4.0 deep |
| Pigtail exit gap | y 20.9–23.5, full rib height |
| Pigtail guide channel | 1.6 mm |
| Boost-to-board channels | 2 × 3.5 mm, below the board |
| Peg pitch | 14.4 mm, ±0.80 mm absorbed, 2 pairs |
| Boost cradle | 18.8 × 12.3 mm, 7.5 mm depth clearance |
| Boost PCB grip range | 0.6 – 1.8 mm |
| Wall / floor / lid | 1.6 / 1.6 / 2.8 mm |

---

## Printing

- PETG, 0.4 mm nozzle, 0.2 mm layer, 4 walls, 25 % infill
- **No supports.** The USB aperture is split across the parting line, and
  every hole either opens downward or bridges under 18 mm.
- Base prints floor down; lid prints top face down, as exported
- The switch pegs print as horizontal features and sag slightly on their
  undersides. Dress them with a blade before fitting the switch.

---

## Assembly

**Prepare**

1. Clean the two switch pegs until the frame drops on without forcing.
   Take material off the undersides first — that is where sag collects.
2. Slide the M3 nut into the lid boss through the slot on the
   antenna-bay side. A dab of glue makes it permanent.

**Base**

3. Fit the slide switch onto the posts, actuator through the slot, and
   glue.
4. Lay the cell in the left bay against its backstop. Do not glue it, and
   do not fill the 1.0 mm space above it. If it rattles, lay a strip of
   Kapton across it and stick that to the bay walls, not to the pouch.

**Lid**

6. Wipe the lid antenna recess with IPA and adhere the FPC. PETG is a
   poor adhesive substrate — abrade it lightly if the bond feels weak.
7. Fit the XIAO: connector into the aperture first, then press the rear
   edge up past the retention ramps.
8. Route the U.FL pigtail out of the board pocket through the gap at
   y 20.9–23.5 and through the guide posts at x 34.
9. Press the boost module into its cradle with the pad edge facing the
   board, until both end fingers snap over it.

**Wiring** — work with the halves side by side, and allow **60 mm** per
run so the lid can lie flat during service.

9. Cut the JST plug off the cell. Solder its leads to BAT+ and BAT− on
   the underside of the XIAO, bend the wires flat immediately, and put a
   blob of hot glue over the joint. Those pads lift if a wire is tugged.
10. Wire cell + to the switch common, and the switched output to both the
    XIAO BAT+ and the boost Vin. Switching off then kills the boost as
    well, so its output cannot fight a host's VBUS when a PC is plugged
    into the USB-C port to reflash.
11. Wire cell − to boost GND.
12. Wire boost 5V and GND to VUSB and GND on the XIAO, passing them
    through the two channels in the end stop — one lead per channel.
    Twist both the input and output pairs tightly; loop area is what
    radiates.
13. Check whether En has a pull-up on your boost module. If not, tie it
    to Vin.

**Close**

14. Dress the battery leads out through the wire channel and hook them
    through the anchor posts.
15. Route the boost leads forward along the gap at x 25.3–28.6 to reach
    the wire channel.
16. Lower the lid — the skirt slides inside the base walls — then fit the
    M3 from underneath and snug it.

---

## Adjusting the fit

Open the `.scad` in OpenSCAD and use View → Customizer. Everything is a
named parameter.

| If | Change |
|---|---|
| The lid is tight or loose | `skirt_gap` |
| The board is tight or loose | `pcb_fit_x`, `pcb_fit_y` |
| The board needs more or less retention | `lip` |
| The switch pegs are tight or loose | `post_d`, `post2_d`, in 0.05 steps |
| The pegs will not reach both holes | `post2_y` — narrower absorbs more |
| The switch actuator binds | `sw_travel` — set to your measured throw |
| The on/off markings are the wrong way round | `mark_flip` |
| The switch sits high or low | `sw_cz` |
| The cell measures over 6 mm | `bat_z`, or `bat_swell` for headroom |
| The boost module is a different size | `boost_l`, `boost_w` |
| The boost fingers grip loosely or not at all | `boost_wedge`, `boost_tab_off` |
| The boost pocket is tight or loose | `boost_fit` |
| The wire anchors are tight for your gauge | `anchor_gap`, `anchor_h` |
| The U.FL sits at the other end of the board | `coax_y0`, `coax_y1` |
| The boost-to-board channels are tight | `endch_w`, `endch_gap` |

---

## Limitations

No gasket, an open USB aperture, an open switch slot, an unsealed parting
line: this is IP00. Bag and bench use only.

The switch frame and the boost module both sit above the antenna bay
region, and the case has no shielding. If the boost's switching noise
raises your HF noise floor, fit a ferrite on the USB lead and consider
lining the lid over the boost with copper tape bonded to battery
negative.
