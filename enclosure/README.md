# XIAO ESP32S3 BLE-CAT enclosure — v4

Side-by-side bays, board on the lid, single central M3.
**57.2 x 42.2 x 17.5 mm** (v3 was 15.7 tall).

## What the review changed

| # | Finding | Fix | Verified |
|---|---|---|---|
| CRIT-1 | Lips had no lead-in; board could not be inserted | Ramped lip over 1.4 mm | Clear span 18.10 at ramp foot -> 16.95 at crest -> 18.20 in pocket |
| CRIT-2 | B+/B- solder joints had 0.82 mm to the lid | Seat 0.8 -> 1.6, lid 1.6 -> 2.4, 14 x 10 x 1.0 relief pocket | 2.62 mm over the pads |
| CRIT-3 | TPU pad consumed the whole swell allowance | Bay 7.0 -> 8.0 | 1.00 mm spare above the cell |
| MAJ-4 | Lid held only at the centre | skirt_gap 0.2 -> 0.1, stepped lead-in so it still starts easily | — |
| MAJ-5 | 0.6 mm of board Y slack cycling the USB joints | pcb_fit_y 0.30 -> 0.15 | 0.3 mm slack |
| MAJ-6 | No strain relief on the battery wires | Two anchor posts on the lid, 1.5 mm channel | — |
| MIN | Floor vents were an ingress path for no benefit | Deleted; the USB aperture vents the case | — |
| MIN | Pry notches left 0.6 mm of wall | Deleted; undo the bolt and the lid lifts | — |
| MIN | Feed notch left a 0.9 mm sliver at the boss | Moved to y = 34 | — |

Board pocket is now 18.2 x 21.4 (was 18.8 x 21.7). The width came in
0.6 mm because the retention lips need to overlap the board by more than
half its side-to-side slack, or they let go.

## Dimensions
- Battery bay 27 x 39 x 8.0 | antenna bay 20 x 39 | pocket 18.2 x 21.4
- USB-C aperture 9.6 x 3.8 at z 8.8-12.6; connector sits 9.1-12.3
- Bolt axis x = 32.1, y = 21.1

## Hardware
1x M3 hex socket head **8 mm**, 1x M3 nut, 1x M3 washer.

Nut slides in through the slot on the antenna-bay side and bears on
2.6 mm of material above it. Washer under the head — 2.4 mm of PETG will
dish if you crank it. Snug only.

## Print settings (P2S)
- PETG, 0.4 nozzle, 0.2 layer, 4 walls, 25% infill, no supports
- Lid bridges 14 x 10 over the relief pocket and the base bridges 5.8 mm
  over the nut slot; both are routine
- Pad in TPU 95A

## Assembly
1. Nut into the boss slot
2. FPC antenna into the right bay — abrade and IPA the floor first, PETG
   is a poor adhesive substrate
3. Cut the PH2.0 plug off the pack. Solder to B+/B-, bend the wires flat
   immediately, hot glue the joint. Leave **60 mm** of wire so the lid
   can lie flat beside the base during service
4. Wire through the anchor posts
5. U.FL pigtail over the rib through the feed notch
6. TPU pad, then cell, into the left bay
7. Board into the lid: connector into the aperture first, then press the
   rear edge up past the ramps
8. Lid down, one bolt, snug

## Known limits
- IP00. No gasket, open aperture, open seam. Bag and bench only.
- Single central fastener: the corners are held by skirt friction alone.
  If the lid lifts at the ends in use, drop skirt_gap to 0.05.
