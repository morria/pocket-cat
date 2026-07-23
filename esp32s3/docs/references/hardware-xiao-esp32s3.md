# Seeed Studio XIAO ESP32S3 — Hardware Reference

Board notes relevant to running the ESP32-S3 as a **USB host** for the radio's
CAT interface. See `../implementation.md` §2 for the design-level treatment;
this is the pin/electrical cheat sheet.

> Sources: Seeed XIAO ESP32S3 wiki & schematic (`wiki.seeedstudio.com`),
> Espressif ESP32-S3 datasheet / Technical Reference Manual (USB-OTG chapter).
> `wiki.seeedstudio.com` is egress-blocked in this session — verify pin numbers
> against the schematic PDF at bring-up.

## SoC

- **ESP32-S3** (dual-core Xtensa LX7 @ up to 240 MHz), Wi-Fi + BLE 5.0 (LE).
- 8 MB flash, 8 MB PSRAM on the XIAO ESP32S3 module.
- Two USB-capable peripherals:
  - **USB-OTG (full-speed, 12 Mbps)** — can be host or device. **This is what we
    use in host mode** to talk to the radio.
  - **USB-Serial-JTAG** — console/JTAG; shares the same physical D+/D− pads as
    USB-OTG on the ESP32-S3, so when OTG host mode owns the port, the
    Serial-JTAG console is unavailable (hence UART0 console, below).

## USB / native-USB pins

| Signal | GPIO | Note |
|--------|------|------|
| USB D− | **GPIO19** | routed to the USB-C connector |
| USB D+ | **GPIO20** | routed to the USB-C connector |

In host mode the firmware drives these via the ESP-IDF `usb_host` stack. The
XIAO exposes no separate host connector — **the same USB-C port** is the host
port, so a USB-C→USB (OTG) adapter connects the radio.

## Power / VBUS — the #1 enumeration trap

- The XIAO's 5 V rail reaches the USB-C VBUS pin only through a **Schottky diode
  oriented for charging** (VBUS→5V), so the board **cannot source 5 V out of the
  USB-C connector by default**. A bus-powered device (e.g. the FT-891's CP2105)
  therefore gets no VBUS and never enumerates.
- Two fixes (pick one; document in `hardware.md`):
  1. **Powered USB-C OTG cable / adapter** that injects external 5 V on VBUS —
     *recommended*, no board mod, no back-power hazard.
  2. **Bridge the VBUS diode** (solder jumper) so the XIAO's 5 V feeds VBUS.
     ⚠️ **Then never power the XIAO from a PC and the bench supply at the same
     time** — bridging ties two 5 V sources together.
- Power the XIAO itself from the `5V`/`GND` pads (or `BAT` pads) while it hosts.

## Console & flashing (native USB is busy)

With USB-OTG in host mode, the USB-Serial-JTAG console/DFU is unavailable:

- **Console/logs → UART0:** `TX = GPIO43`, `RX = GPIO44`. Set
  `CONFIG_ESP_CONSOLE_UART_DEFAULT` (UART0) in sdkconfig; attach a 3.3 V USB-UART
  dongle. (These are the same pins the board labels TX/RX.)
- **Flashing:** hold **BOOT**, tap **RESET** to enter the serial bootloader,
  then flash over the UART0 dongle (`esptool`/`idf.py -p <uart> flash`). This
  keeps the radio cable untouched — the bench CI runner should use this path.
  Alternative for one-offs: unplug the radio and flash over native USB
  (BOOT+RESET → USB bootloader).

## Other pins used by the firmware

| Function | GPIO | Note |
|----------|------|------|
| User LED | **GPIO21** | link-state signalling (`../implementation.md` §5.6). Active-low on XIAO. |
| UART0 TX | GPIO43 | console |
| UART0 RX | GPIO44 | console |
| BOOT btn | GPIO0 | bootloader entry |

## XIAO 14-pin header (for reference)

Standard XIAO pinout: 11 GPIO broken out plus `5V`, `GND`, `3V3`. Peripheral
defaults: I²C `SDA=GPIO5 / SCL=GPIO6`, UART `TX=GPIO43 / RX=GPIO44`, SPI
`SCK/MISO/MOSI` on the SPI block, 9× ADC. None of the header GPIOs are required
for the bridge beyond UART0 + the LED, leaving them free for future PTT/CW
line-level control if the app ever wants hardware keying.
