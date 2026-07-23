# ESP32-S3 BLE↔USB CAT Bridge

Firmware for a Seeed XIAO ESP32S3 that bridges a BLE central (iOS app) to a
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

## Build & flash

```sh
cd firmware
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor   # UART0 dongle on GPIO43/44 (§2.1)
```

The native USB-C port runs in host mode (radio side), so console + flashing
go over a UART0 dongle; hold BOOT at reset for the ROM downloader. VBUS must
be supplied to the radio — measure the 5V↔VBUS net first
([`docs/references/hardware-xiao-esp32s3.md`](docs/references/hardware-xiao-esp32s3.md)).

Debug build without BLE bonding (bench only — LED triple-blinks):
`idf.py menuconfig` → CAT Bridge BLE → uncheck "Require LE encryption".

## Tests

```sh
make -C test/host run                  # 57 C tests: unit + e2e simulation
python -m pytest test/tools -q         # 32 tests: codec, radio_sim, pty rig
```

Hardware-in-the-loop (docs §7.3/§7.4): run `radio_sim.py` on a CP2105/CP2102/
CDC fixture attached to the ESP32's USB port, and drive BLE with
`ble_client.py` (`status`, `cat "FA;"`, `echo`, `storm`) and `soak.py`.
CI builds the firmware (ESP-IDF v5.3) and runs every host suite on each push.
