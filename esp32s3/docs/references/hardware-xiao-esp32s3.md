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

A bus-powered USB device (e.g. the FT-891's CP2105) draws its 5 V *from the
host* over VBUS. In host mode the XIAO must therefore **source** 5 V out of the
USB-C connector — the opposite of its normal role. If VBUS stays unpowered, the
radio never enumerates and there is no error, just silence.

### ⚠️ Measure before you modify — you probably don't need a solder mod

On the XIAO ESP32S3 the **`5V` pad and the USB-C VBUS pin are the same net**
(VBUS is pin 14 / the `5V` pad). The common, widely-used approach is simply to
**feed 5 V into the `5V` pad**; it reaches USB-C VBUS and powers the peripheral
with **no board modification**. Verify on your actual board first:

1. Multimeter, continuity mode: probe the `5V` pad against the USB-C shell/VBUS
   pin. ~0 Ω → the rail is already connected; inject 5 V on `5V` and you're done.
2. If instead you read a diode drop (~0.3 V) or an open, there is a series part
   in the path — identify its **exact designator from the official schematic**
   (Seeed wiki → Resources), confirm with the meter, then bridge that part.

> Earlier revisions of this note asserted an onboard Schottky diode always
> blocks the 5 V→VBUS direction. That is **not confirmed** for this board and is
> commonly the *opposite* of reality (the "diode" in Seeed forum threads is an
> **external** part you add to stop back-feeding when combining USB-C with an
> external 5 V source — an expansion-board concern). Trust the measurement + the
> schematic over any blog photo of a possibly-different revision.

### Options, in order of preference

1. **Inject 5 V on the `5V` pad** (after confirming `5V`↔VBUS continuity) —
   simplest, no mod. Power the XIAO from `5V`/`GND` (or `BAT`) and VBUS follows.
2. **Powered USB-C OTG cable / adapter** that injects external 5 V on VBUS —
   no board mod, no back-power hazard; good when you can't reach the `5V` pad.
3. **Bridge the in-path component** (only if step 1's measurement shows one, and
   only after identifying it on the schematic) so the `5V` rail feeds VBUS.
   ⚠️ **Then never power the XIAO from a PC and a bench/external 5 V supply at
   the same time** — that ties two 5 V sources together. Pick one source.

Note: this whole concern is really about the **bus-powered Yaesu** radios
(CP2105/CP210x). The **QMX is self-powered** over native USB, so it is unlikely
to depend on host VBUS at all — confirm per-radio at bring-up.

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
