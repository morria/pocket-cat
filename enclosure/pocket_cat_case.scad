// =====================================================================
// XIAO ESP32S3 BLE-CAT enclosure  --  v4
//
// Side-by-side bays, board on the lid, single central M3.
// Modelled in ASSEMBLED coordinates; print flip applied at export only.
//
// v4 changes (adversarial review):
//   CRIT-1  retention lips now ramped -- board can actually be inserted
//   CRIT-2  relief pocket in a 2.4 mm lid + taller seat = 2.6 mm over the
//           B+/B- solder joints (was 0.82)
//   CRIT-3  battery bay 7.0 -> 8.0 so the TPU pad stops eating the swell
//           allowance (was 0.00 spare, now 1.00)
//   MAJ-4   skirt_gap 0.2 -> 0.1, stepped lead-in on the skirt
//   MAJ-5   pcb_fit_y 0.30 -> 0.15, board Y slack 0.6 -> 0.3
//   MAJ-6   wire anchor posts on the lid
//   MIN     floor vents deleted, pry notches deleted, feed notch moved
//           clear of the bolt boss
//
// v5: bolt reversed. Enters from the base underside, head fully recessed
//     flush with the bottom face; nut is now captive in a boss on the lid.
//     Nothing protrudes from either outer face.
//
// Units: mm.  OpenSCAD 2021.01 or later.
// =====================================================================

/* [Part selection] */
part = "all";   // base | lid | lidasm | pad | assembly | all

/* [Battery - 602535 pouch cell] */
bat_x = 25;
bat_y = 37;
bat_z = 6;
bat_swell = 1.0;   // clearance ABOVE the cell

/* [Antenna - flat FPC] */
ant_x = 18;
ant_y = 37;
ant_fit = 0.4;      // recess clearance
ant_rec_d = 0.4;    // recess depth in the lid inner face

/* [Board - Seeed XIAO ESP32S3, measured] */
pcb_x = 17.7;
pcb_y = 21.1;
pcb_t = 1.2;
pcb_fit_x = 0.15;
pcb_fit_y = 0.15;
pcb_seat = 1.6;    // gap between PCB top face and lid inner face
lip = 0.5;         // retention lip, ramped
lip_h = 2.6;       // ramp height below the PCB - longer = shallower cam
rib_t = 1.2;       // pocket rib thickness - thinner = more compliant
tab_l = 5.0;       // length of each retention tab
slot_w = 0.8;      // relief slot isolating each tab
tab_y = [4.0, 12.4];  // tab start, local to the pocket
usbc_w = 9.0;
usbc_h = 3.2;
usbc_over = 2.9;
usb_clr = 0.3;

/* [Pad relief - clearance over the B+/B- solder joints] */
relief_inset = 0.3;  // relief now spans the WHOLE pocket, not a patch
relief_d = 1.2;
wire_y0  = 12.6;   // wire escape channel, lands inside existing slots
wire_y1  = 15.6;
wire_x0  = 3.5;
wire_x1  = 26.0;
// second gap, at the far end of the board, for the U.FL pigtail
coax_y0  = 20.9;
coax_y1  = 23.5;
coax_post_d = 1.8;   // guide posts for the pigtail run to the divider rib
coax_post_h = 4.0;
coax_post_x = 34.0;
coax_post_y = [29.3, 32.7];
// twin channels through the pocket end stop, for the boost-to-XIAO run
endch_w   = 3.5;    // each channel width
endch_gap = 2.0;    // web left between them

/* [Case] */
wall = 1.6;
floor_t = 1.6;
lid_t = 2.8;       // thickened to carry the relief pocket
rib = 7.0;
clr = 1.0;
corner_r = 2.0;
skirt_h = 7.5;     // deeper: buys headroom over the cell for the boost
rear_bay = 5.0;    // extra interior length for the boost module
skirt_w = 1.6;
skirt_gap = 0.1;
skirt_lead = 0.6;  // stepped lead-in at the skirt free edge

/* [Fastener] */
boss_d = 9.0;
bolt_d = 3.4;
nut_af = 5.6;
nut_t = 2.5;
nut_slot_w = 5.8;
head_d = 6.2;      // M3 socket head clearance
head_h = 3.0;      // counterbore depth in the base underside
lboss_d = 9.0;     // nut boss on the lid
lead_h = 1.5;      // conical lead-in for the bolt tip

/* [Boost module - TPS61023 MiniBoost clone] */
boost_l = 17.8;
boost_w = 11.3;
boost_t = 4.5;      // ESTIMATE: PCB + inductor, header off. Only sets the
                    // rib height; the bay clears up to 7.5 mm regardless.
boost_fit = 0.50;   // per side - 0.25 printed too close to fit
boost_rib_h = 2.5;
boost_rib_t = 1.6;
boost_gap = 10.0;   // opening in the pad-edge rib for solder access
// Compliant retention fingers. The retaining face is a wedge, not a
// square shoulder, so it clamps any PCB from boost_grip_min to
// boost_grip_max thick instead of needing one exact thickness.
boost_tab_w   = 5.0;
boost_tab_l   = 4.0;    // finger length below the lid inner face
boost_tab_t   = 1.0;    // finger thickness - thin so it flexes
boost_tab_gap = 0.4;    // relief each side of the finger
boost_tab_off = 0.15;   // finger face standoff from the board edge
boost_wedge   = 1.1;    // wedge protrusion - raised to match the looser pocket
boost_grip_min = 0.6;   // thinnest PCB the wedge will catch
boost_grip_max = 1.8;   // thickest

/* [Power switch - wall mounted in the antenna bay] */
// SS12F15 (SS12F15G5). Drawing tolerance is +/-5%, so the pitch is
// absorbed by the peg pair below rather than matched exactly.
sw_frame_l   = 19.8;    // overall length including the mounting ears
sw_frame_w   = 4.6;     // ear width
sw_pitch_spec = 14.4;   // hole centres - scaled off the drawing, not a spec
sw_hole_d    = 2.2;
sw_act_l     = 3.0;     // knob, along the travel axis
sw_act_h     = 3.0;     // knob, across
sw_travel    = 3.0;     // set to the measured throw once you have one
sw_slot_clr_l = 0.4;
sw_slot_clr_h = 0.6;
// Two switches. S1 is the master on/off; S2 selects run or charge.
// Off in S1 makes the illegal state (boost live with BAT connected)
// unreachable, and S2 being SPDT makes it exclusive by construction.
sw_cy        = [12.6, 34.6];
sw_cz        = 5.5;     // frame centre height above the base underside
post_d       = 1.90;    // round peg: locates the switch
post_tip_d   = 1.60;
post2_d      = 2.00;    // lozenge peg: full height across the pitch axis,
post2_tip_d  = 1.70;    //   narrow along it, so pitch error floats out
post2_y      = 0.90;
post_taper_l = 1.0;     // tapered lead-in
post_flat    = 0.15;    // shaved underside: pre-compensates for print sag
post_h       = 3.0;
// no skirt relief needed: the 4.6 mm frame and 5.6 mm body clear 8.60

/* [Panel markings] */
// IEC 60417: bar = on (5007), ring = off (5008). Drawn as primitives
// rather than text() so they do not depend on a font being installed.
mark_d    = 0.5;    // engraving depth
mark_h    = 3.5;    // symbol height / ring outside diameter
mark_w    = 0.9;    // stroke width
mark_gap  = 1.6;    // clear space between slot edge and symbol
mark_h_tri = 4.4;   // triangle drawn larger: it tapers, so it reads small
mark_flip = 0;      // set to 1 to swap which side gets the bar

/* [Feed line] */
feed_w = 7.0;
feed_d = 3.5;
feed_y = 34.0;

/* [Wire anchor] */
anchor_d   = 2.0;   // post diameter
anchor_gap = 3.6;   // clear channel - two 22 AWG silicone leads (~1.7 OD)
anchor_h   = 4.0;   // depth below the lid inner face
anchor_y0  = 5.0;   // first post centre

/* [Hidden] */
$fn = 64;
eps = 0.01;

// ---------- derived ----------
bat_bay_x = bat_x + 2*clr;
bat_bay_z = bat_z + bat_swell;              // 7.0
ant_bay_x = ant_x + 2*clr + 2.0;   // widened: the lid needs the span
inner_x   = bat_bay_x + rib + ant_bay_x;
inner_y   = max(bat_y, ant_y) + 2*clr + rear_bay;
inner_z   = bat_bay_z + skirt_h;
ext_x     = inner_x + 2*wall;
ext_y     = inner_y + 2*wall;
base_h    = floor_t + inner_z;
total_h   = base_h + lid_t;

lid_inner = base_h;
part_z    = floor_t + bat_bay_z;

pcb_cx    = wall + bat_bay_x/2;
pocket_x  = pcb_x + 2*pcb_fit_x;
pocket_y  = pcb_y + 2*pcb_fit_y;
pocket_x0 = pcb_cx - pocket_x/2;
pocket_y0 = wall + skirt_gap + skirt_w;

pcb_top   = lid_inner - pcb_seat;
pcb_bot   = pcb_top - pcb_t;
rib_bot   = pcb_bot - lip_h;

usb_w     = usbc_w + 2*usb_clr;
usb_bot   = pcb_bot - usbc_h - usb_clr;
usb_top   = pcb_bot + usb_clr;

sw_pitch  = sw_pitch_spec;
sw_wall_x = wall + inner_x;                               // inner face, +X wall
mark_s    = (mark_flip > 0) ? -1 : 1;
mark_half = (sw_act_l + sw_travel + sw_slot_clr_l) / 2;
mark_off1 = mark_half + mark_gap + mark_w/2;    // bar
mark_off2 = mark_half + mark_gap + mark_h/2;       // ring, bolt
mark_offt = mark_half + mark_gap + mark_h_tri/2;  // triangle

lboss_bot = part_z + 0.5;                 // lid boss reaches down to here
nut_bot   = lboss_bot + 1.5;              // pocket floor under the nut
nut_relief = lid_inner - (nut_bot + nut_t);   // stops at the lid inner face

bat_stop  = wall + 2*clr + bat_y;      // rear face of the cell pocket
ant_stop  = wall + 2*clr + ant_y;
boost_pl  = boost_l + 2*boost_fit;
boost_pw  = boost_w + 2*boost_fit;
ant_rec_w = ant_x + ant_fit;
ant_rec_l = ant_y + ant_fit;
ant_rec_x = (((wall + bat_bay_x + rib/2) + lboss_d/2)
              + (wall + inner_x - skirt_gap - skirt_w)) / 2
            - ant_rec_w/2;
ant_rec_y = wall + inner_y/2 - ant_rec_l/2;

boost_cx  = (wall + skirt_gap + skirt_w + wall + bat_bay_x) / 2;
boost_cy  = (pocket_y0 + pocket_y + 1.6 + wall + skirt_gap
             + (inner_y - 2*skirt_gap) - skirt_w) / 2;

boss_cx   = wall + bat_bay_x + rib/2;
boss_cy   = wall + inner_y/2;

skirt_ox  = inner_x - 2*skirt_gap;
skirt_oy  = inner_y - 2*skirt_gap;

// ---------- helpers ----------
module rrect(x, y, r, h) {
    linear_extrude(height = h)
        offset(r = r) offset(delta = -r) square([x, y]);
}

// Locating rib with a RAMPED retention lip protruding +X.
// Board enters from below, cams the lip outward, seats on the shoulder.
// Continuous locating rib, lipless, cut into segments by relief slots so
// each retention tab can flex on its own instead of dragging the whole fin.
module pocket_side(len) {
    difference() {
        translate([0, 0, rib_bot]) cube([rib_t, len, lid_inner - rib_bot]);
        for (ty = tab_y)
            for (sy = [ty - slot_w, ty + tab_l])
                translate([-eps, sy, rib_bot - eps])
                    cube([rib_t + 2*eps, slot_w, lid_inner - rib_bot + 2*eps]);
    }
}

// Ramped retention wedges. Lip protrudes +X; the ramp rises over lip_h so
// the board cams the tab outward gradually instead of hitting a step.
module lip_tabs() {
    for (ty = tab_y)
        translate([0, ty + tab_l - 0.2, 0])
            rotate([90, 0, 0])
                linear_extrude(height = tab_l - 0.4)
                    polygon(points = [[rib_t - 0.2, rib_bot],
                                      [rib_t + lip, pcb_bot],
                                      [rib_t - 0.2, pcb_bot]]);
}

// Horizontal mounting peg: cylindrical land at the wall, tapered lead-in
// at the tip, and a shaved underside so print sag lands back on round.
// Horizontal locating peg. Pass ywid < d to get a lozenge: full height
// across the pitch axis, narrow along it.
module sw_peg(d, tip, ywid) {
    intersection() {
        difference() {
            union() {
                rotate([0, -90, 0])
                    cylinder(d = d, h = post_h - post_taper_l);
                translate([-(post_h - post_taper_l), 0, 0])
                    rotate([0, -90, 0])
                        cylinder(d1 = d, d2 = tip, h = post_taper_l);
            }
            translate([-post_h - eps, -d, -d/2 - 1])
                cube([post_h + 2*eps, 2*d, 1 + post_flat]);
        }
        translate([-post_h - 1, -ywid/2, -d])
            cube([post_h + 2, ywid, 2*d]);
    }
}

// Compliant retention finger for the boost cradle. Wedge face spans a
// range of board thicknesses; shallow lead-in below it for insertion.
module boost_finger() {
    translate([0, boost_tab_w/2, 0])
        rotate([90, 0, 0])
            linear_extrude(height = boost_tab_w)
                polygon(points = [
                    [-boost_tab_t, lid_inner],
                    [0,            lid_inner],
                    [0,            lid_inner - boost_grip_min],
                    [boost_wedge,  lid_inner - boost_grip_max],
                    [0,            lid_inner - boost_tab_l],
                    [-boost_tab_t, lid_inner - boost_tab_l]]);
}

module mk_bar(y) {
    translate([ext_x - mark_d, y - mark_w/2, sw_cz - mark_h/2])
        cube([mark_d + eps, mark_w, mark_h]);
}
module mk_ring(y) {
    translate([ext_x - mark_d, y, sw_cz]) rotate([0, 90, 0])
        difference() {
            cylinder(d = mark_h, h = mark_d + eps);
            translate([0, 0, -eps])
                cylinder(d = mark_h - 2*mark_w, h = mark_d + 3*eps);
        }
}
// Lightning bolt (charge), built as two slanted strokes so the stroke
// width is explicit rather than falling out of the outline geometry.
// Polygon space is (-dz, dy): rotate([0,90,0]) maps the plane that way.
module seg2d(p1, p2, w) {
    d = p2 - p1;
    translate([(p1[0] + p2[0])/2, (p1[1] + p2[1])/2])
        rotate(atan2(d[1], d[0]))
            square([norm(d), w], center = true);
}
module mk_bolt(y) {
    a = mark_h/2;
    translate([ext_x - mark_d, y, sw_cz]) rotate([0, 90, 0])
        linear_extrude(height = mark_d + eps)
            union() {
                seg2d([-1.00*a,  0.34*a], [0,        -0.29*a], mark_w);
                seg2d([0,         0.29*a], [1.00*a,  -0.34*a], mark_w);
            }
}
module mk_tri(y) {
    a = mark_h_tri/2;
    translate([ext_x - mark_d, y, sw_cz]) rotate([0, 90, 0])
        linear_extrude(height = mark_d + eps)
            polygon(points = [[a, -a], [-a, -a], [0, a]]);
}

// =====================================================================
// BASE
// =====================================================================
module base() {
    difference() {
        union() {
            difference() {
                rrect(ext_x, ext_y, corner_r, base_h);
                translate([wall, wall, floor_t])
                    cube([inner_x, inner_y, inner_z + eps]);
            }
            translate([wall + bat_bay_x, wall, floor_t])
                cube([rib, inner_y, bat_bay_z]);
            // cell backstop - the bay is now longer than the cell
            translate([wall, bat_stop, floor_t])
                cube([bat_bay_x, 2.0, bat_bay_z]);
            translate([boss_cx, boss_cy, floor_t])
                cylinder(d = boss_d, h = bat_bay_z);   // stub, up to rib height

            // switch mounting pegs, one round + one lozenge per switch
            for (cy = sw_cy) {
                translate([sw_wall_x, cy - sw_pitch/2, sw_cz])
                    sw_peg(post_d, post_tip_d, post_d);
                translate([sw_wall_x, cy + sw_pitch/2, sw_cz])
                    sw_peg(post2_d, post2_tip_d, post2_y);
            }
        }

        // actuator slots
        for (cy = sw_cy)
            translate([sw_wall_x - eps,
                       cy - (sw_act_l + sw_travel + sw_slot_clr_l)/2,
                       sw_cz - (sw_act_h + sw_slot_clr_h)/2])
                cube([wall + 2*eps,
                      sw_act_l + sw_travel + sw_slot_clr_l,
                      sw_act_h + sw_slot_clr_h]);

        // panel markings: S1 bar/ring (on/off), S2 triangle/bolt (run/charge)
        mk_bar(sw_cy[0] + mark_off1);
        mk_ring(sw_cy[0] - mark_off2);
        mk_tri(sw_cy[1] + mark_offt);
        mk_bolt(sw_cy[1] - mark_off2);

        // wiring notches through the divider rib, one per switch
        for (cy = sw_cy)
            translate([wall + bat_bay_x - eps, cy - feed_w/2, part_z - feed_d])
                cube([rib + 2*eps, feed_w, feed_d + eps]);

        // recessed head counterbore, opening at the base underside
        translate([boss_cx, boss_cy, -eps])
            cylinder(d = head_d, h = head_h + eps);
        // bolt clearance, all the way through the stub
        translate([boss_cx, boss_cy, head_h - eps])
            cylinder(d = bolt_d, h = part_z);

        // USB-C window, lower half
        translate([pcb_cx - usb_w/2, -eps, usb_bot])
            cube([usb_w, wall + 2*eps, base_h - usb_bot + eps]);
    }
}

// =====================================================================
// LID, assembled orientation
// =====================================================================
module lid() {
    difference() {
        union() {
            translate([0, 0, lid_inner]) rrect(ext_x, ext_y, corner_r, lid_t);

            // skirt, with a stepped lead-in at the free edge
            translate([wall + skirt_gap, wall + skirt_gap, part_z + skirt_lead])
                difference() {
                    cube([skirt_ox, skirt_oy, skirt_h - skirt_lead]);
                    translate([skirt_w, skirt_w, -eps])
                        cube([skirt_ox - 2*skirt_w, skirt_oy - 2*skirt_w,
                              skirt_h + 2*eps]);
                }
            translate([wall + skirt_gap + 0.35, wall + skirt_gap + 0.35, part_z])
                difference() {
                    cube([skirt_ox - 0.7, skirt_oy - 0.7, skirt_lead + eps]);
                    translate([skirt_w - 0.35, skirt_w - 0.35, -eps])
                        cube([skirt_ox - 2*skirt_w, skirt_oy - 2*skirt_w,
                              skirt_lead + 4*eps]);
                }

            // board pocket
            translate([pocket_x0 - rib_t, pocket_y0, 0]) {
                pocket_side(pocket_y + 0.6);
                lip_tabs();
            }
            translate([pocket_x0 + pocket_x + rib_t, pocket_y0, 0])
                mirror([1, 0, 0]) {
                    pocket_side(pocket_y + 0.6);
                    lip_tabs();
                }
            translate([pocket_x0 - rib_t - 0.3, pocket_y0 + pocket_y, rib_bot])
                cube([pocket_x + 2*rib_t + 0.6, 1.6, lid_inner - rib_bot]);

            // nut boss, hanging from the lid
            translate([boss_cx, boss_cy, lboss_bot])
                cylinder(d = lboss_d, h = lid_inner - lboss_bot);

            // boost module cradle, open on the pad edge for soldering
            difference() {
                translate([boost_cx - boost_pl/2 - boost_rib_t,
                           boost_cy - boost_pw/2 - boost_rib_t,
                           lid_inner - boost_rib_h])
                    cube([boost_pl + 2*boost_rib_t,
                          boost_pw + 2*boost_rib_t, boost_rib_h]);
                translate([boost_cx - boost_pl/2, boost_cy - boost_pw/2,
                           lid_inner - boost_rib_h - eps])
                    cube([boost_pl, boost_pw, boost_rib_h + 2*eps]);
                // 0.5 mm lead-in chamfer at the mouth so the module starts square
                hull() {
                    translate([boost_cx - (boost_pl + 1.0)/2,
                               boost_cy - (boost_pw + 1.0)/2,
                               lid_inner - boost_rib_h - eps])
                        cube([boost_pl + 1.0, boost_pw + 1.0, 0.01]);
                    translate([boost_cx - boost_pl/2, boost_cy - boost_pw/2,
                               lid_inner - boost_rib_h + 0.6])
                        cube([boost_pl, boost_pw, 0.01]);
                }
                translate([boost_cx - boost_gap/2,
                           boost_cy - boost_pw/2 - boost_rib_t - eps,
                           lid_inner - boost_rib_h - eps])
                    cube([boost_gap, boost_rib_t + 2*eps,
                          boost_rib_h + 2*eps]);
                // relief so each retention finger can flex on its own
                for (sx = [-1, 1])
                    translate([boost_cx + sx*(boost_pl/2 + boost_rib_t) - eps
                               - (sx > 0 ? 0 : boost_rib_t),
                               boost_cy - boost_tab_w/2 - boost_tab_gap,
                               lid_inner - boost_rib_h - eps])
                        cube([boost_rib_t + 2*eps,
                              boost_tab_w + 2*boost_tab_gap,
                              boost_rib_h + 2*eps]);
            }
            // Retention fingers sit at the board's nominal edge, not at the
            // rib. The ribs are a loose locating fit; the fingers alone
            // provide grip, so the two can be tuned independently.
            translate([boost_cx - (boost_l/2 + boost_tab_off), boost_cy, 0])
                boost_finger();
            translate([boost_cx + (boost_l/2 + boost_tab_off), boost_cy, 0])
                mirror([1, 0, 0]) boost_finger();

            // wire anchor posts, just inboard of the divider rib
            // pigtail guide posts, between the nut boss and the feed notch
            for (yy = coax_post_y)
                translate([coax_post_x, yy, lid_inner - coax_post_h])
                    cylinder(d = coax_post_d, h = coax_post_h);

            for (yy = [anchor_y0, anchor_y0 + anchor_d + anchor_gap])
                translate([pocket_x0 + pocket_x + rib_t + 0.65 + anchor_d/2, yy,
                           lid_inner - anchor_h])
                    cylinder(d = anchor_d, h = anchor_h);
        }

        // relief over the whole board footprint. The pads are not where
        // a small patch can reliably cover them, so relieve the lot.
        translate([pocket_x0 + relief_inset, pocket_y0 + relief_inset,
                   lid_inner - eps])
            cube([pocket_x - 2*relief_inset, pocket_y - 2*relief_inset,
                  relief_d + eps]);

        // wire escape: full-height gap through BOTH pocket ribs plus a
        // groove in the lid, giving a continuous channel from over the
        // board out into the bay. Ends land inside existing relief slots
        // so no retention tab is touched.
        translate([wire_x0, wire_y0, rib_bot])
            cube([wire_x1 - wire_x0, wire_y1 - wire_y0,
                  lid_inner + relief_d - rib_bot]);

        // boost-to-XIAO wire channels through the end stop. Cut below the
        // board only, so the stop still blocks the PCB's rear edge.
        for (sx = [-1, 1])
            translate([pcb_cx + sx*endch_gap/2 - (sx < 0 ? endch_w : 0),
                       pocket_y0 + pocket_y - eps, rib_bot])
                cube([endch_w, 1.6 + 2*eps, pcb_bot - rib_bot]);

        // pigtail exit, below the board only so the lid stays full thickness
        translate([wire_x0, coax_y0, rib_bot])
            cube([wire_x1 - wire_x0, coax_y1 - coax_y0, lid_inner - rib_bot]);

        // local skirt relief above the switch frame
        // (skirt relief removed: the frame now clears the skirt)

        // antenna recess, locates the FPC on the lid inner face
        translate([ant_rec_x, ant_rec_y, lid_inner - eps])
            cube([ant_rec_w, ant_rec_l, ant_rec_d + eps]);

        // USB-C window, upper half
        translate([pcb_cx - usb_w/2, wall - 1, part_z - eps])
            cube([usb_w, skirt_w + 2, usb_top - part_z + eps]);

        // captive nut pocket, side-loaded from the antenna bay
        translate([boss_cx, boss_cy, nut_bot])
            cylinder(d = nut_af / cos(30), h = nut_t, $fn = 6);
        translate([boss_cx, boss_cy - nut_slot_w/2, nut_bot])
            cube([lboss_d, nut_slot_w, nut_t]);
        // thread relief above the nut
        translate([boss_cx, boss_cy, nut_bot + nut_t - eps])
            cylinder(d = bolt_d, h = nut_relief);
        // bolt entry through the boss floor, with a conical lead-in
        translate([boss_cx, boss_cy, lboss_bot - eps])
            cylinder(d1 = 5.0, d2 = bolt_d, h = lead_h);
        translate([boss_cx, boss_cy, lboss_bot + lead_h - eps])
            cylinder(d = bolt_d, h = nut_bot - lboss_bot);
    }
}

module lid_for_print() {
    translate([ext_x, 0, total_h]) rotate([0, 180, 0]) lid();
}

// ---------- output ----------
if (part == "base") base();
else if (part == "lid") lid_for_print();
else if (part == "lidasm") lid();
else if (part == "assembly") { base(); lid(); }
else {
    base();
    translate([0, ext_y + 6, 0]) lid_for_print();
}
