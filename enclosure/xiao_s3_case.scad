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
// Units: mm.  OpenSCAD 2021.01 or later.
// =====================================================================

/* [Part selection] */
part = "all";   // base | lid | lidasm | pad | assembly | all

/* [Battery - 602535 pouch cell] */
bat_x = 25;
bat_y = 37;
bat_z = 6;
pad_t = 1.0;       // TPU pad under the cell
bat_swell = 1.0;   // clearance ABOVE the cell, over and above the pad

/* [Antenna - flat FPC] */
ant_x = 18;
ant_y = 37;

/* [Board - Seeed XIAO ESP32S3, measured] */
pcb_x = 17.7;
pcb_y = 21.1;
pcb_t = 1.2;
pcb_fit_x = 0.25;
pcb_fit_y = 0.15;
pcb_seat = 1.6;    // gap between PCB top face and lid inner face
lip = 0.7;         // retention lip, ramped
lip_h = 1.4;       // ramp height below the PCB
usbc_w = 9.0;
usbc_h = 3.2;
usbc_over = 2.9;
usb_clr = 0.3;

/* [Pad relief - clearance over the B+/B- solder joints] */
relief_x = 14;
relief_y = 10;
relief_d = 1.0;

/* [Case] */
wall = 1.6;
floor_t = 1.6;
lid_t = 2.4;       // thickened to carry the relief pocket
rib = 7.0;
clr = 1.0;
corner_r = 2.0;
skirt_h = 5.5;
skirt_w = 1.6;
skirt_gap = 0.1;
skirt_lead = 0.6;  // stepped lead-in at the skirt free edge

/* [Fastener] */
boss_d = 9.0;
bolt_d = 3.4;
nut_af = 5.6;
nut_t = 2.5;
nut_z = 10.0;
nut_slot_w = 5.8;

/* [Feed line] */
feed_w = 7.0;
feed_d = 3.5;
feed_y = 34.0;

/* [Wire anchor] */
anchor_d = 2.0;
anchor_gap = 1.5;
anchor_h = 2.5;

/* [Hidden] */
$fn = 64;
eps = 0.01;

// ---------- derived ----------
bat_bay_x = bat_x + 2*clr;
bat_bay_z = pad_t + bat_z + bat_swell;      // 8.0
ant_bay_x = ant_x + 2*clr;
inner_x   = bat_bay_x + rib + ant_bay_x;
inner_y   = max(bat_y, ant_y) + 2*clr;
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
module pocket_rib(len) {
    translate([0, len, 0])
        rotate([90, 0, 0])
            linear_extrude(height = len)
                polygon(points = [[0, rib_bot],
                                  [1.6, rib_bot],          // ramp foot
                                  [1.6 + lip, pcb_bot],    // ramp crest
                                  [1.6, pcb_bot],          // shoulder
                                  [1.6, lid_inner],
                                  [0, lid_inner]]);
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
            translate([boss_cx, boss_cy, floor_t])
                cylinder(d = boss_d, h = inner_z);
        }

        // U.FL feed notch, clear of the bolt boss
        translate([wall + bat_bay_x - eps, feed_y - feed_w/2, part_z - feed_d])
            cube([rib + 2*eps, feed_w, feed_d + eps]);

        // bolt hole, blind
        translate([boss_cx, boss_cy, nut_z - 2.0])
            cylinder(d = bolt_d, h = inner_z);

        // captive nut pocket, side-loaded from the antenna bay
        translate([boss_cx, boss_cy, nut_z])
            cylinder(d = nut_af / cos(30), h = nut_t, $fn = 6);
        translate([boss_cx, boss_cy - nut_slot_w/2, nut_z])
            cube([boss_d, nut_slot_w, nut_t]);

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
            translate([pocket_x0 - 1.6, pocket_y0, 0]) pocket_rib(pocket_y);
            translate([pocket_x0 + pocket_x + 1.6, pocket_y0, 0])
                mirror([1, 0, 0]) pocket_rib(pocket_y);
            translate([pocket_x0 - 1.6, pocket_y0 + pocket_y, rib_bot])
                cube([pocket_x + 3.2, 1.6, lid_inner - rib_bot]);

            // wire anchor posts, just inboard of the divider rib
            for (yy = [8, 8 + anchor_d + anchor_gap])
                translate([wall + bat_bay_x - 1.4, yy, lid_inner - anchor_h])
                    cylinder(d = anchor_d, h = anchor_h);
        }

        // relief pocket over the B+/B- solder joints
        translate([pcb_cx - relief_x/2, pocket_y0, lid_inner - eps])
            cube([relief_x, relief_y, relief_d + eps]);

        // USB-C window, upper half
        translate([pcb_cx - usb_w/2, wall - 1, part_z - eps])
            cube([usb_w, skirt_w + 2, usb_top - part_z + eps]);

        // bolt clearance
        translate([boss_cx, boss_cy, lid_inner - 1])
            cylinder(d = bolt_d, h = lid_t + 2);
    }
}

module pad() { rrect(bat_x, bat_y, 2, pad_t); }

module lid_for_print() {
    translate([ext_x, 0, total_h]) rotate([0, 180, 0]) lid();
}

// ---------- output ----------
if (part == "base") base();
else if (part == "lid") lid_for_print();
else if (part == "lidasm") lid();
else if (part == "pad") pad();
else if (part == "assembly") { base(); lid(); }
else {
    base();
    translate([0, ext_y + 6, 0]) lid_for_print();
    translate([ext_x + 6, 0, 0]) pad();
}
