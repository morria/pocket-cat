# XIAO ESP32S3 + 602535 LiPo + 37x18 FPC antenna enclosure

Layout A: battery and antenna sit in separate bays on the base floor,
separated by a 3 mm rib. The board mounts to the lid, above the battery,
so nothing conductive sits over the antenna bay.

## Files
| File | Material | Notes |
|---|---|---|
| `xiao_s3_base.stl` | PETG | Prints floor down, no supports |
| `xiao_s3_lid.stl` | PETG | Prints top face down, no supports |
| `xiao_s3_pad.stl` | TPU 95A | Goes under the pouch cell |
| `xiao_s3_case.scad` | — | Parametric source, OpenSCAD customizer ready |

## Dimensions
- Closed: 53.2 x 42.2 x 15.7 mm
- Battery bay: 27 x 39 x 7 mm (1 mm of that is swell allowance)
- Antenna bay: 20 x 39, full depth
- Antenna to battery foil: 5 mm lateral
- PCB underside to battery top: 3.5 mm
- Verified: both halves watertight, zero interference when assembled

## Print settings (P2S)
- PETG, 0.4 mm nozzle, 0.2 mm layer
- 4 walls, 25% infill (walls carry the snap fit, infill does not)
- No supports, no brim needed
- The USB-C window is split across the parting line, so neither part
  bridges anything

## Assembly
1. Cut the PH2.0 connector off the pack, or fit a mating pigtail.
   The XIAO charges through B+/B- solder pads, not a connector.
2. Solder to B+/B-, then anchor the wires with a dab of hot glue at the
   pad edge. Those pads lift if the wire is ever tugged.
3. Stick the FPC antenna into the antenna bay with its own adhesive.
4. Route the U.FL pigtail over the divider rib. The rib is deliberately
   short so it clears.
5. TPU pad into the battery bay, cell on top, board clipped into the lid
   ribs, USB-C into the window notch.
6. Lid skirt slides inside the base walls and lands on the ledge at the
   top of the battery bay.

## Tuning
Open the `.scad` in OpenSCAD, View > Customizer. Every fit is a named
parameter. The ones you are most likely to touch after measuring your
actual cell with calipers: `bat_x`, `bat_y`, `bat_z`, `clr`, and
`skirt_gap` if the lid is tight or loose.
