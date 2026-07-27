# QRP Labs QMX — CAT Reference

The QMX implements a **subset of the Kenwood TS-480 / TS-440 CAT command set**
(ASCII, `;`-terminated) — "based loosely on the TS-480, with one or two minor
additions and exceptions" (QRP Labs). This is a *different dialect* from the
Yaesu radios, so the iOS app selects it by the `STATUS` radio-id enum.

> Source of record: *QMX CAT reference* — QRP Labs
> (`qrp-labs.com/images/qmx/manuals/cat_1_02_006.pdf`) and the *Kenwood TS-480
> PC Control Command* reference. Mode codes cross-checked against Hamlib
> `rigs/kenwood/kenwood.c` → `kenwood_mode_table[]`.

## Physical / serial layer

- **USB:** native STM32 **USB CDC-ACM** (composite: also presents a USB sound
  card for digital audio). No SiLabs bridge chip. Enumerates by USB **class**
  (CDC-ACM), not a fixed VID/PID the bridge should hard-match — detect by class.
- **Baud rate is cosmetic / ignored:** it's native USB, so line coding doesn't
  gate communication. The bridge still honors `SET_BAUD` so `SET_LINE_CODING`
  requests succeed and host software that insists on a rate is happy.
- **Framing:** 8-N-1 by convention. `;` (0x3B) terminator, same as Yaesu.

## Command syntax

```
<2-letter opcode>[params];
```

Same Set / Read / Answer shape as Kenwood:

- **Set:** `FA00014250000;`
- **Read:** `FA;`
- **Answer:** `FA00014250000;`
- Kenwood uses **11-digit** frequency fields (vs Yaesu's 9). Mind the width.

## Supported commands (verified against the QMX CAT manual, fw 1_02_006)

Grounded in *QMX CAT programming manual, firmware 1.02_006* (30-Oct-2025) —
the authoritative source. Alphabetical:

| Op | Function | Notes |
|----|----------|-------|
| `AG` | AF gain | 0.25 dB steps; `AG091;` = 22.75 dB. `AG;` or `AG0;` read. |
| `C2` | Signal generator | Si5351A Clk2 frequency get/set. |
| `FA` | VFO-A frequency | **11 digits** on read. `FA7030000;` set works too. |
| `FB` | VFO-B frequency | 11 digits, Hz. |
| `FR`/`FT` | VFO mode | 0/1/2 = VFO A / VFO B / Split (both commands). |
| `FW` | Filter bandwidth | read-only: `3200` digi, `0300` CW. |
| `ID` | Radio ID | always `ID020;` (TS-480). `OM;` → `OMQC;` tells QMX apart. |
| `IF` | Information | TS-480 layout: freq, RIT, TX flag, mode, VFO, split. |
| `KS` | Keyer speed (WPM) | get/set. |
| `KY` | CW message keying | `KY <text>;` — two formats per TS-480-compat menu. |
| `LC` | LCD contents | read-only, 32 chars of the 1602 screen. |
| `MD` | Mode | **only `3` CW, `6` DIGI/FSK, `7` CW-R, `9` FSK-R** (below). |
| `ML`/`MM` | **Menu Manager** | full config-tree discovery + get/set (below). |
| `PC` | Output power | **GET-only, tenths of a watt**: `PC45;` = 4.5 W measured. |
| `Q0`–`QC` | QRP Labs extensions | session-only params (below). |
| `RC`/`RD`/`RU`/`RT` | RIT | clear / down / up / status; abs. or relative per config. |
| `RX`/`TX`/`TQ` | PTT | `RX;` unkeys (**← `SET_FAILSAFE` payload**), `TX;` keys, `TQn;` get/set. |
| `SA` | AGC meter | read-only, gain attenuation in dB. |
| `SM` | S-meter | read-only, **value in dB** (not TS-480 4-digit form). |
| `SP` | Split | `SP0;`/`SP1;` get/set. |
| `SS` | SSB TX source | 0 USB audio / 1 two-tone test / 2 mic. |
| `SW` | SWR meter | read-only, hundredths (`SW121;` = 1.21:1); empty in RX. |
| `TA` | TX audio tone | digi-mode key-down tone in fractional Hz; `TA0;` keys up. |
| `TB` | CW decoder buffer | read-only, drains the 40-char decode buffer. |
| `TM` | Real-time clock | `TM135532;` get/set hhmmss. |
| `VN` | Firmware version | e.g. `VN1_02_006QMX;`. |

## `MD` — mode codes (QMX subset)

Single digit, `MD<code>;`. **QMX accepts only:**

| Code | Mode |
|------|------|
| `3` | CW |
| `6` | DIGI (FSK) |
| `7` | CW-R |
| `9` | FSK-R |

There is no LSB/USB/AM/FM via `MD` — sideband is the `Q1` extension
(`Q11;` = LSB, other = USB; session-only, not saved to EEPROM).

## `MM` / `ML` — Menu Manager (full configuration access)

The QMX exposes its **entire configuration menu tree** over CAT:

- **Get:** `MM<path>;` → `MM<value>;`
- **Set:** `MM<path>=<value>;` — **persisted to EEPROM** (unlike the
  two-letter commands and `Q` extensions, which are session-only).
- **Discovery:** `MM<path>|<index>?;` → `MM<type>|<len>|<name>;` walks the
  tree; `MM<index>?;` at the root. Types: 0 sub-menu, 1 action/app,
  2 string, 3 number, 4 byte, 5 list, 6 info, 7 mask.
- **List options:** `ML<listType>;` → `ML<opt>|<opt>|…;` for list items.

Paths are `|`-delimited menu names (case-insensitive) or numeric indexes,
e.g. `MMAudio|AGC settings|Threshold S;`. Grid pages (Band config.) take an
array subscript: `MMBand config.|RF gain (db)[3];`. Items whose *name* is
numeric (CW filter rows) must be addressed by index. Error reply is `?;`.

## `Q0`–`QC` — QRP Labs extensions (session-only)

`Q0` TCXO ref freq · `Q1` sideband · `Q2` VFO A (= `FA`) · `Q3` VOX ·
`Q4`/`Q5` TX rise/fall thresholds · `Q6`/`Q7`/`Q8` cycle/sample/discard ·
`Q9` IQ mode · `QA` Japanese band limits · `QB`/`QC` CAT timeout
enable/seconds. None are saved to EEPROM.

## `KY` — CW keying

`KY<text>;` sends the text as CW at the current keyer speed (`KS`). This is the
**CAT-mediated** way to send CW and works fine over the BLE bridge. Note this is
*buffered message* keying, **not** real-time element timing — consistent with
the bridge's non-goal of timing-accurate keying (`../implementation.md` §1).
`KY;` (read) reports keyer buffer availability on TS-480; behavior on QMX per
the CAT PDF.

## `IF` — information

Kenwood `IF;` returns a fixed-width status string (freq, RIT/XIT, mode, VFO,
TX/RX, etc.). Field widths differ from Yaesu's — use the TS-480 layout, and have
the app validate offsets against a live QMX. Like Yaesu, it's the one-shot poll
for freq + mode + TX state.

## Notes for the app

- Distinct dialect: **11-digit** frequencies, single-digit modes, `TX;`/`RX;`
  (not `TX1;`/`TX0;`) for PTT, Kenwood mode numbering.
- `RX;` is the failsafe unkey string to arm before `TX;`.
- Don't rely on baud; QMX ignores it. Still send `SET_BAUD` so line-coding
  succeeds.
- Model detect: `ID;` → `ID020;` (TS-480 family). Combine with the USB CDC-ACM
  enumeration to distinguish QMX from a Yaesu on the bridge's `STATUS` enum.
