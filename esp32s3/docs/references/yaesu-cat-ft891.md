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

## Passband commands — `IS`, `SH`, `BP`, `BC`, `CO`

**Provenance: researched 2026-07-28 from Hamlib master** (`rigs/yaesu/newcat.c`
`is_ft891` branches; width tables from `ft991.c`, shared with the FT-891 by
`ft891.c`), cross-checked against the FT-891 ext-param declarations. **Not yet
verified against hardware** — treat each row as high-confidence but confirm on
the bench before shipping UI that writes it (`docs/passband.md` §2), then mark
it verified here.

### `IS` — IF shift

- **Set:** `IS0` + `P2` + signed 4-digit Hz + `;` where `P2` is `0` when the
  value is 0 and `1` otherwise: `IS01+0250;`, `IS01-1000;`, clear `IS00+0000;`.
- **Read:** `IS0;` → same shape back.
- **Range:** ±1200 Hz (Hamlib `max_ifshift`). Step: the radio's front panel
  steps 20 Hz — whether CAT rounds is a bench item.
- Hamlib gates AM/FM rejection only on other models; assume the FT-891 also
  rejects in AM/FM and disable in UI (bench-confirm).

### `SH` — width (index, not Hz)

- **Set (FT-891-specific):** `SH0` + `1` + 2-digit index + `;` — the extra `1`
  is an "on" digit this rig requires: `SH0112;`. **Read:** `SH0;`.
- **Set `NA` first**: narrow mode must be correct *before* the width write
  (Hamlib does exactly this ordering). Widths ≤ `narrow_max` need `NA01;`,
  wider need `NA00;`.
- **Index → Hz tables** (shared FT-891/FT-991; index 0 = rig default):

| Mode family | narrow_max | idx 1… |
|---|---|---|
| CW / RTTY / DATA | 500 | 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 800, 1200, 1400, 1700, 2000, 2400, 3000 (idx 1–17) |
| SSB | 1800 | 200, 400, 600, 850, 1100, 1350, 1500, 1650, 1800, 1950, 2100, 2200, 2300, 2400, 2500, 2600, 2700, 2800, 2900, 3000, 3200 (idx 1–21) |
| AM | — | no `SH`; width = `NA` narrow toggle (9000/6000) |
| FM | — | no `SH`; `NA` toggle (16000/9000) |

### `BP` — manual notch

- **On/off:** `BP00001;` on, `BP00000;` off. **Read:** `BP00;`.
- **Frequency:** `BP01` + 3 digits + `;` in **10 Hz units**, clamped 001–320
  (= 10–3200 Hz): `BP01123;` = 1230 Hz. **Read:** `BP01;`.
- Hamlib writes freq and on/off independently (no required ordering) —
  bench-confirm the radio accepts freq-while-off.

### `BC` — auto notch (DNF)

- `BC00;` off, `BC01;` on. **Read:** `BC0;`. Mutual exclusivity with the
  manual notch is undocumented — bench item.

### `CO` — contour (and APF)

- **Contour on/off:** `CO00` + 4-digit value + `;` → `CO000001;` on,
  `CO000000;` off. **Read:** `CO00;`.
- **Contour frequency:** `CO01` + 4-digit Hz + `;`, range 10–3200 Hz,
  1 Hz wire resolution: `CO010800;`.
- **Level (−40…+20 dB) and width (1–11)** are *menu items*, not CAT ops, on
  this rig (Hamlib ext params; the app's menu catalog already carries the
  CONTOUR LEVEL/WIDTH items) — the strip's handle therefore has one CAT axis
  (frequency) plus menu-backed depth.
- **APF** (audio peak filter, CW): `CO02` + 4-digit on/off → `CO020001;`;
  APF width is menu `EX1201n;`. Noted for a future CW view; not part of the
  passband strip v1.
