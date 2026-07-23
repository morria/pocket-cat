# Yaesu FT-891 — CAT Reference

CAT (Computer Aided Transceiver) command reference for the FT-891. The FT-891
uses the modern Yaesu ASCII CAT dialect shared with the FT-991A / FT-DX
families. **The bridge forwards these bytes verbatim; this document is for the
iOS app**, which constructs and parses them.

> Source of record: *FT-891 CAT Operation Reference Book* (Yaesu). Mode codes
> and serial defaults below cross-checked against Hamlib `rigs/yaesu/newcat.c`
> and `rigs/yaesu/ft891.c`.

## Physical / serial layer

- **USB bridge chip:** Silicon Labs **CP2105** (dual UART). VID `0x10C4`,
  PID `0xEA70`. CAT is on the **Enhanced (ECI)** interface; the Standard (SCI)
  interface carries TX/PTT/keying lines. (Confirm the interface index against a
  real radio — see `../implementation.md` §5.2.)
- **Framing:** 8 data bits, no parity, 1 stop bit (**8-N-1**). No hardware flow
  control required for CAT.
- **Baud (menu `05-06 CAT RATE`):** `4800` (factory default), `9600`, `19200`,
  `38400`. Hamlib lists min 4800 / max 38400. **The bridge defaults to 4800 to
  match a factory-fresh radio;** the app raises it via `SET_BAUD`.
- **Related menus:** `05-07 CAT TOT` (CAT time-out timer), `05-08 CAT RTS`
  (whether the radio watches the RTS line). If `CAT RTS = ENABLE`, the host must
  assert RTS or the radio ignores CAT — relevant to the bridge's `SET_LINE`
  control opcode.

## Command syntax

```
<2-letter opcode>[parameters];        ← every command ends with ';' (0x3B)
```

- **Set:** send opcode + params + `;`  (e.g. `FA014250000;`)
- **Read:** send opcode + `;`          (e.g. `FA;`)
- **Answer:** radio replies with opcode + data + `;` (e.g. `FA014250000;`)
- **Invalid command:** radio replies `?;`
- **Auto-information** (if `AI` on): radio emits status frames unsolicited.

There is **no** checksum. Responses are delimited solely by `;`, which is why
the bridge can use `;` as a low-latency notification-flush hint without parsing.

## Frequently used commands

| Op | Function | Set format | Read | Answer format |
|----|----------|-----------|------|---------------|
| `FA` | VFO-A frequency (Hz) | `FA` + 9 digits + `;` | `FA;` | `FA` + 9 digits + `;` |
| `FB` | VFO-B frequency (Hz) | `FB` + 9 digits + `;` | `FB;` | 9 digits |
| `MD` | Operating mode | `MD0` + code + `;` | `MD0;` | `MD0` + code + `;` |
| `IF` | Information (composite state) | — (read only) | `IF;` | see layout below |
| `TX` | PTT / transmit control | `TX1;` (on) / `TX0;` (off) | `TX;` | `TX0`=RX,`TX1`/`TX2`=TX |
| `PS` | Power on/off | `PS0;`/`PS1;` | `PS;` | `PS0`/`PS1` |
| `AI` | Auto-information mode | `AI0;`/`AI1;` | `AI;` | `AI0`/`AI1` |
| `ID` | Radio identification | — | `ID;` | `ID0650;` (FT-891) |
| `VS` | VFO A/B select | `VS0;`/`VS1;` | `VS;` | `VS0`/`VS1` |
| `SH` | Width / filter | `SH0` + nn + `;` | `SH0;` | width index |
| `NA` | Narrow on/off | `NA0` + n + `;` | `NA0;` | — |
| `RM` | Read meter (S/PO/ALC/SWR…) | `RM` + n + `;` | `RM` + n + `;` | meter value |
| `SM` | S-meter reading | — | `SM0;` | `SM0` + nnn + `;` |
| `PC` | RF power (TX power) | `PC` + nnn + `;` | `PC;` | power |
| `KS` | Keyer speed (WPM) | `KS` + nnn + `;` | `KS;` | speed |
| `KY` | Send CW text (memory keyer) | `KY` + text + `;` | — | — |
| `BI` | Break-in | `BI0;`/`BI1;` | `BI;` | — |
| `MG` | Mic gain | `MG` + nnn + `;` | `MG;` | gain |
| `AG` | AF gain | `AG0` + nnn + `;` | `AG0;` | gain |
| `RG` | RF gain | `RG0` + nnn + `;` | `RG0;` | gain |
| `SQ` | Squelch level | `SQ0` + nnn + `;` | `SQ0;` | level |
| `NB` | Noise blanker | `NB0` + n + `;` | `NB0;` | — |
| `NR` | Noise reduction | `NR0` + n + `;` | `NR0;` | — |
| `PA` | Preamp / IPO | `PA0` + n + `;` | `PA0;` | — |
| `RA` | RF attenuator | `RA0` + n + `;` | `RA0;` | — |
| `FT` | Function TX (split select) | `FT0;`/`FT1;` | `FT;` | — |
| `ST` | Split on/off (some fw) | `ST0;`/`ST1;` | `ST;` | — |
| `BD`/`BU` | Band down / up | `BD0;` / `BU0;` | — | — |
| `UP`/`DN` | Freq step up / down | `UP;` / `DN;` | — | — |

> This is the working subset. The reference book lists the full set (~90
> commands incl. memory channels `MC`, `MW`, menu `EX`, CTCSS/DCS, etc.). Treat
> the PDF as authoritative for anything not above.

## `MD` — mode codes (Yaesu newcat)

Set/read uses `MD0<code>;` (the `0` is the "P1" fixed digit on the FT-891).

| Code | Mode | Code | Mode |
|------|------|------|------|
| `1` | LSB | `9` | RTTY-U (RTTY-R) |
| `2` | USB | `A` | DATA-FM (PKT-FM) |
| `3` | CW-U | `B` | FM-N |
| `4` | FM | `C` | DATA-USB (PKT-USB) |
| `5` | AM | `D` | AM-N |
| `6` | RTTY-L (FSK) | `E` | C4FM |
| `7` | CW-L (CW-R) | `F` | DATA-FM-N (PKT-FM-N) |
| `8` | DATA-LSB (PKT-LSB) | | |

Example: `MD03;` → CW; read `MD0;` → `MD03;`.

## `FA` / `FB` — frequency

9 ASCII digits, Hz, zero-padded. `FA014250000;` = 14.250 000 MHz on VFO-A.
Read `FA;` returns the same 9-digit form.

## `IF` — information (read-only status snapshot)

`IF;` returns a fixed-width Yaesu status string. Field widths follow the
FT-991A/FT-891 layout (total 27 chars of payload + `IF` + `;`):

```
IF <memch:3> <vfo/freq:9> <clar:+/-nnnn:5> <rx clar:1> <tx clar:1>
   <mode:1> <p7:1> <ctcss/dcs:1> <p8:2> <simplex/split:1> ;
```

Practical parse (the app should treat exact offsets as radio-specific and
verify against the PDF + a live rig):

- chars 3–5: memory channel
- chars 6–14: operating frequency (Hz, 9 digits)
- chars 15–19: clarifier offset (signed, 4 digits)
- char 20: RX clarifier on/off
- char 21: TX clarifier on/off
- char 22: mode (same code table as `MD`)
- char 23: VFO/memory ("P7")
- char 24: CTCSS/DCS
- chars 25–26: tone ("P8")
- char 27: `0`=simplex, `1`=+shift, `2`=−shift / split flag

`IF;` is the canonical single-poll the app should use for a fast state refresh
(freq + mode + TX status in one round trip).

## `TX` — PTT

- `TX0;` → receive (unkey). **This is the recommended `SET_FAILSAFE` payload**
  the app arms before keying (`../implementation.md` §4.1).
- `TX1;` → transmit via CAT.
- Read `TX;` → `TX0;` (RX), `TX1;`/`TX2;` (TX, source-dependent).

## Notes for the app

- Poll cadence: `IF;` at 2–5 Hz is plenty; add `SM0;` for the S-meter while RX
  and `RM` meters while TX. Command timeout ~300 ms, one retry, then surface.
- Frequency is Hz — no decimal handling on the wire.
- Always `TX0;` on teardown; also arm the failsafe so a dropped BLE link unkeys.
- `ID;` → `ID0650;` confirms an FT-891 once CAT is talking at the right baud;
  use it as the baud-probe token.
