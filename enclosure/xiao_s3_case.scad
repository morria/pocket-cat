// =====================================================================
// XIAO ESP32S3 + 602535 LiPo + 37 x 18 FPC antenna enclosure
// Layout A: battery and antenna in separate floor bays, board on the lid
// Units: mm.  OpenSCAD 2021.01 or later.
// =====================================================================

/* [Part selection] */
part = "all";   // base | lid | pad | all

/* [Battery - 602535 pouch cell] */
bat_x = 25;
bat_y = 37;
bat_z = 6;
bat_swell = 1.0;   // pouch swelling headroom - do not remove

/* [Antenna - flat FPC] */
ant_x = 18;
ant_y = 37;

/* [Board - Seeed XIAO ESP32S3] */
pcb_x = 18;
pcb_y = 20;
pcb_t = 1.2;
pcb_fit = 0.4;     // per-side slip fit
pcb_seat = 0.8;    // standoff under the PCB
usbc_h = 3.2;      // connector shell height above the PCB

/* [Case] */
wall = 1.6;
floor_t = 1.6;
lid_t = 1.6;
rib = 3.0;
clr = 1.0;
corner_r = 2.0;
skirt_h = 5.5;
skirt_w = 1.6;
skirt_gap = 0.2;

/* [Openings] */
usb_w = 12;
vent_w = 2;
vent_l = 20;
pry_w = 10;
pry_d = 1.0;

/* [Hidden] */
$fn = 48;
eps = 0.01;

// ---------- derived ----------
bat_bay_x = bat_x + 2*clr;              // 27
bat_bay_z = bat_z + bat_swell;          // 7
ant_bay_x = ant_x + 2*clr;              // 20
inner_x   = bat_bay_x + rib + ant_bay_x;        // 50
inner_y   = max(bat_y, ant_y) + 2*clr;          // 39
inner_z   = bat_bay_z + skirt_h;                // 12.5  (bay + skirt landing)
ext_x     = inner_x + 2*wall;
ext_y     = inner_y + 2*wall;
base_h    = floor_t + inner_z;                  // 14.1
total_h   = base_h + lid_t;                     // 15.7

bat_cx    = wall + bat_bay_x/2;         // shared centreline: bay, board, USB window

skirt_ox  = inner_x - 2*skirt_gap;
skirt_oy  = inner_y - 2*skirt_gap;
skirt_x0  = wall + skirt_gap;
skirt_y0  = wall + skirt_gap;
in_y0     = skirt_y0 + skirt_w;

pocket_x  = pcb_x + 2*pcb_fit;
pocket_y  = pcb_y + 2*pcb_fit;
rib_h     = pcb_seat + pcb_t + 1.4;

// USB window: must span the connector, which sits at lid-local
// z = lid_t + pcb_seat + pcb_t .. + usbc_h
usb_lid_d = skirt_h - pcb_seat - pcb_t + 0.4;   // notch up from the skirt free edge
usb_base_d = skirt_h + 0.6;                     // notch down from the base rim

// ---------- helpers ----------
module rrect(x, y, r, h) {
    linear_extrude(height = h)
        offset(r = r) offset(delta = -r)
            square([x, y]);
}

module lip_rib(len) {   // retention rib, lip overhangs toward +X
    translate([0, len, 0])
        rotate([90, 0, 0])
            linear_extrude(height = len)
                polygon(points = [[0, 0], [1.6, 0],
                                  [1.6, pcb_seat + pcb_t],
                                  [2.2, pcb_seat + pcb_t],
                                  [2.2, rib_h], [0, rib_h]]);
}

// =====================================================================
// BASE - prints floor down, no supports
// =====================================================================
module base() {
    difference() {
        union() {
            difference() {
                rrect(ext_x, ext_y, corner_r, base_h);
                translate([wall, wall, floor_t])
                    cube([inner_x, inner_y, inner_z + eps]);
            }
            // divider rib, only as tall as the battery bay so the
            // U.FL pigtail can pass freely over the top
            translate([wall + bat_bay_x, wall, floor_t])
                cube([rib, inner_y, bat_bay_z]);
        }

        // USB-C window, lower half
        translate([bat_cx - usb_w/2, -eps, base_h - usb_base_d])
            cube([usb_w, wall + 2*eps, usb_base_d + eps]);

        // battery bay floor vents
        for (i = [-1, 0, 1])
            translate([bat_cx + i*7 - vent_w/2,
                       wall + inner_y/2 - vent_l/2, -eps])
                cube([vent_w, vent_l, floor_t + 2*eps]);

        // pry notches under the lid rim
        for (yy = [-eps, ext_y - pry_d + eps])
            translate([ext_x/2 - pry_w/2, yy, base_h - 2])
                cube([pry_w, pry_d, 2 + eps]);
    }
}

// =====================================================================
// LID - modelled top face down, which is also the print orientation
// =====================================================================
module lid() {
    difference() {
        union() {
            rrect(ext_x, ext_y, corner_r, lid_t);

            translate([skirt_x0, skirt_y0, lid_t])
                difference() {
                    cube([skirt_ox, skirt_oy, skirt_h]);
                    translate([skirt_w, skirt_w, -eps])
                        cube([skirt_ox - 2*skirt_w,
                              skirt_oy - 2*skirt_w, skirt_h + 2*eps]);
                }

            // board pocket
            translate([bat_cx - pocket_x/2 - 1.6, in_y0, lid_t])
                lip_rib(pocket_y);
            translate([bat_cx + pocket_x/2 + 1.6, in_y0, lid_t])
                mirror([1, 0, 0]) lip_rib(pocket_y);
            translate([bat_cx - pocket_x/2 - 1.6,
                       in_y0 + pocket_y - 0.5, lid_t])
                cube([pocket_x + 3.2, 2.1, rib_h]);
        }

        // USB-C window, upper half
        translate([bat_cx - usb_w/2, skirt_y0 - 1,
                   lid_t + skirt_h - usb_lid_d])
            cube([usb_w, skirt_w + 2, usb_lid_d + eps]);
    }
}

// =====================================================================
// PAD - print in TPU, sits under the pouch cell
// =====================================================================
module pad() {
    rrect(bat_x, bat_y, 2, 1.0);
}

// ---------- output ----------
if (part == "base") base();
else if (part == "lid") lid();
else if (part == "pad") pad();
else {
    base();
    translate([0, ext_y + 6, 0]) lid();
    translate([ext_x + 6, 0, 0]) pad();
}
