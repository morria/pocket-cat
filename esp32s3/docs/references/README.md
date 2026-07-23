# Reference Documentation

Curated, offline reference material for building the ESP32-S3 BLE↔USB CAT
bridge. These documents distill the authoritative sources into the specific
facts the firmware and the iOS app need, so implementers don't have to re-derive
CAT formats, USB IDs, or pinouts mid-task.

## What's here

| File | Covers |
|---|---|
| [`yaesu-cat-ft891.md`](yaesu-cat-ft891.md) | FT-891 CAT command set, serial format, IF/FA/MD field layouts |
| [`yaesu-cat-ftx1.md`](yaesu-cat-ftx1.md) | FTX-1 CAT notes, USB dual-CP210x enumeration, deltas vs FT-891 |
| [`qmx-cat.md`](qmx-cat.md) | QMX CAT (Kenwood TS-480 subset), mode codes, KY keying, quirks |
| [`hardware-xiao-esp32s3.md`](hardware-xiao-esp32s3.md) | XIAO ESP32S3 pinout, USB-OTG host mode, VBUS/power, console/flash |
| [`usb-cp210x-cdc.md`](usb-cp210x-cdc.md) | CP2102/CP2105 & CDC-ACM USB descriptors, VID/PID, interface map |
| [`firmware-esp-idf-usb-host-vcp.md`](firmware-esp-idf-usb-host-vcp.md) | ESP-IDF USB Host stack + esp-usb VCP drivers, lifecycle, line coding |
| [`firmware-nimble-ble.md`](firmware-nimble-ble.md) | NimBLE peripheral/GATT reference for the BLE link |

## How these were verified

The CAT command tables (especially mode codes) were cross-checked against
**Hamlib** (the reference open-source rig-control library, `Hamlib/Hamlib` on
GitHub) so the byte-level formats are grounded in a working implementation, not
just recollection:

- Yaesu `MD` mode codes: `rigs/yaesu/newcat.c` → `newcat_mode_conv[]`.
- FT-891 serial defaults (4800–38400): `rigs/yaesu/ft891.c`.
- Kenwood/QMX `MD` mode codes: `rigs/kenwood/kenwood.c` → `kenwood_mode_table[]`.

## Canonical primary sources (download these too)

These are the manufacturer documents of record. **They are hosted on sites the
session's network egress policy blocks, so they could not be auto-downloaded
into this folder** — grab them from a normal browser and drop the PDFs beside
these notes (add them to `.gitignore` if you'd rather not commit binaries):

- **FT-891 CAT Operation Reference Book** — Yaesu.
  `https://www.rigpix.com/yaesu/ft891_cat_manual.pdf` (mirror), or
  ManualsLib / the Yaesu Files portal.
- **FT-891 Advance / Operating Manual** — Yaesu (menu `05-06 CAT RATE`, etc.).
- **FTX-1 Series CAT Operation Reference Manual** — Yaesu (needs MAIN firmware
  ≥ 1.08). Search "FTX-1 CAT Operation Reference Manual".
- **QMX CAT reference** — QRP Labs:
  `https://qrp-labs.com/images/qmx/manuals/cat_1_02_006.pdf`.
- **Kenwood TS-480 PC Control Command reference** — Kenwood
  (`ts_480_pc.pdf`); the parent spec QMX borrows from.
- **ESP32-S3 Technical Reference Manual** & **datasheet** — Espressif
  (USB-OTG / USB-Serial-JTAG chapters).
- **ESP-IDF USB Host docs** & **esp-usb** component registry — Espressif
  (`docs.espressif.com`, `components.espressif.com`, `github.com/espressif/esp-usb`).
- **XIAO ESP32S3 wiki & schematic** — Seeed Studio (`wiki.seeedstudio.com`).
- **CP210x / CP2105 datasheets & AN571 (USB descriptors)** — Silicon Labs.

> Provenance note: the tables below are engineering references compiled for this
> project. Where a value is safety- or interop-critical (mode codes, VID/PID,
> the CP2105 CAT interface index), verify once against the primary PDF and the
> real radio during bring-up before freezing it — see the acceptance checklist
> in `../implementation.md` §7.5.
