# Pocket Cat — ESP32-S3 BLE↔USB CAT Bridge

Pocket Cat firmware for a Seeed XIAO ESP32S3 that bridges a BLE central (iOS app) to a
transceiver's USB CAT interface (Yaesu FT-891, Yaesu FTX-1, QRP Labs QMX).
The ESP32 is a transparent byte pipe; all CAT protocol logic lives on the
remote. See [`docs/implementation.md`](docs/implementation.md) for the full
design and [`docs/protocol.md`](docs/protocol.md) for the BLE contract.

## Layout

```
firmware/            ESP-IDF (≥5.2) project
  main/              app wiring, bridge task, LED
  components/
    ctrl_proto/      BLE control-channel TLV codec       (pure C, host-tested)
    cat_bridge/      rings, coalescer, detect, core      (pure C, host-tested)
    usb_link/        usb_host + CDC-ACM/CP210x glue
    ble_link/        NimBLE GATT server
test/
  host/              unit + end-to-end simulation suites (gcc + ASan/UBSan)
  tools/             radio_sim.py, ble_client.py, soak.py, catproto.py
docs/                implementation plan, protocol spec, references/
```

## Prerequisites

- **ESP-IDF ≥ 5.2** (CI builds against 5.3) — install per
  [Espressif's getting-started guide](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/).
  Every new shell needs `. $HOME/esp/esp-idf/export.sh`.
- **Python 3** with `pytest pytest-timeout pyserial`, for the tools tests.
- **A USB-to-UART dongle with 3.3 V logic** (CP2102, CH340, FT232) to flash.
  A 5 V-only dongle will damage the board.

Verify with `idf.py --version`.

## Build

```sh
cd firmware
idf.py set-target esp32s3      # once per checkout
idf.py build
```

## Test

Both suites are host-side and need no hardware:

```sh
make -C test/host run              # C: unit + e2e simulation (ASan/UBSan)
python3 -m pytest test/tools -q    # Python: codec, radio_sim, pty rig
```

Both must exit 0. CI runs exactly these on every push.

## Flash

**The native USB-C port cannot be used for flashing** — it runs in host mode
for the radio. Console and bootloader are on UART0, so wire the dongle to the
board first. Note that TX goes to RX:

| Dongle | XIAO ESP32-S3 |
|---|---|
| TX | GPIO44 (RX) |
| RX | GPIO43 (TX) |
| GND | GND |

```sh
idf.py -p /dev/tty.usbserial-XXXX flash monitor    # macOS
idf.py -p /dev/ttyUSB0 flash monitor               # Linux
```

Find the port with `ls /dev/tty.usb*` or `ls /dev/ttyUSB*`. If flashing won't
start, hold **BOOT**, tap **RESET**, release BOOT to enter the ROM downloader,
then run the command again.

Flash **before** the board goes into the enclosure — it mounts component-side
down and the pads become awkward to reach (see [`../BUILD.md`](../BUILD.md)).

VBUS must be supplied to the radio — measure the 5V↔VBUS net first
([`docs/references/hardware-xiao-esp32s3.md`](docs/references/hardware-xiao-esp32s3.md)).

Debug build without BLE bonding (bench only — LED triple-blinks):
`idf.py menuconfig` → CAT Bridge BLE → uncheck "Require LE encryption".

**Working:** `idf.py monitor` shows the bridge booting and it advertises as
`CATBridge-XXXX` in any BLE scanner.

Hardware-in-the-loop (docs §7.3/§7.4): run `radio_sim.py` on a CP2105/CP2102/
CDC fixture attached to the ESP32's USB port, and drive BLE with
`ble_client.py` (`status`, `cat "FA;"`, `echo`, `storm`) and `soak.py`.
CI builds the firmware (ESP-IDF v5.3) and runs every host suite on each push.
