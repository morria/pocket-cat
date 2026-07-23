# USB Serial Bridges — CP210x & CDC-ACM Reference

What the ESP32-S3 USB host sees when each radio is plugged in, and how the
radio-detect table (`../implementation.md` §5.2) uses it. All detection is
**per-interface** to handle composite devices.

> Sources: Silicon Labs CP210x datasheets + AN571 (CP210x USB descriptors),
> USB CDC-ACM (PSTN) class spec, Espressif `esp-usb` driver headers. SiLabs docs
> are egress-blocked here — confirm PIDs with `lsusb -v` at bring-up.

## Silicon Labs CP2105 (FT-891, and FTX-1's dual-UART bridge)

- **Dual UART** bridge. VID `0x10C4`, PID **`0xEA70`**.
- Presents **two serial interfaces** in one device:
  - **Enhanced (ECI)** — the full-featured UART → **carries CAT** on the FT-891.
  - **Standard (SCI)** — reduced UART → PTT/RTTY/keying lines.
- Vendor-specific class (not CDC): controlled with **CP210x vendor requests**,
  not the CDC-ACM `SET_LINE_CODING` standard request. The ESP-IDF
  `usb_host_cp210x` VCP driver wraps these.
- **Interface index:** the firmware opens the Enhanced/CAT interface. **The ECI
  vs SCI ↔ interface-#0 vs #1 mapping must be confirmed on a real FT-891** —
  do not assume (`../implementation.md` §5.2, §9). Line coding, DTR/RTS, and
  purge all go through CP210x vendor control transfers.

## Silicon Labs CP2102 / CP2102N (bench stand-in, generic profile)

- **Single UART**. VID `0x10C4`, PID **`0xEA60`** (CP2102/‑N).
- ⚠️ **Not interchangeable with the CP2105** for testing the FT-891 path:
  different PID, single interface. A CP2102 breakout lands in the bridge's
  **generic CP210x** profile — useful as the FTX-1-candidate / generic test
  vector, **not** as a fake FT-891. Use a real **CP2105** eval board for the
  dual-interface FT-891 path.
- Same CP210x vendor protocol; the `usb_host_cp210x` driver handles both.

## USB CDC-ACM (QMX, and generic-CDC radios)

- **Class-based**, not VID/PID: Communications Device Class, ACM subclass
  (a.k.a. the standard "USB modem"/virtual COM). The QMX's native STM32 USB
  enumerates here.
- Descriptor shape: a **Communications Interface** (class `0x02`, subclass
  `0x02` ACM) + a **Data Interface** (class `0x0A`), usually joined by an IAD in
  a composite device (the QMX also exposes a USB audio function).
- Line coding via the standard **`SET_LINE_CODING` (0x20)** control request; the
  QMX **ignores the baud value** (native USB) but the request must succeed.
- DTR/RTS via **`SET_CONTROL_LINE_STATE` (0x22)**. Driven by the ESP-IDF
  `usb_host_cdc_acm` VCP driver.

## Radio-detect quick table

| Match (per interface) | Profile | CAT iface | Default baud | Driver |
|---|---|---|---|---|
| VID `0x10C4` / PID `0xEA70` | FT-891 (CP2105) | Enhanced/ECI (confirm index) | 4800 | `usb_host_cp210x` |
| VID `0x10C4` / other CP210x PID (incl. `0xEA60`) | generic Yaesu / FTX-1 candidate | the serial iface | 4800 | `usb_host_cp210x` |
| Interface class `0x02` ACM (+ `0x0A` data) | QMX / generic CDC | data iface | n/a (cosmetic) | `usb_host_cdc_acm` |
| VID `0x0403` (FTDI) | fallback generic | serial iface | 4800 | `usb_host_ftdi` |
| anything else | `RADIO_UNSUPPORTED` | — | — | stay attached, report |

## Control-transfer cheat sheet (what `SET_BAUD` / `SET_LINE` map to)

| Bridge op | CDC-ACM | CP210x |
|---|---|---|
| set baud / framing | `SET_LINE_CODING` (0x20) | `CP210X_SET_BAUDRATE` / `SET_LINE_CTL` vendor req |
| assert DTR/RTS | `SET_CONTROL_LINE_STATE` (0x22) | `CP210X_SET_MHS` vendor req |
| purge buffers | (host-side ring purge) | `CP210X_PURGE` vendor req |

The `esp-usb` VCP layer (`../implementation.md`, `usb_link` component) abstracts
these so the bridge issues one logical call regardless of chip.
