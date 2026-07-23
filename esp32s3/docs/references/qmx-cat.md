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

## Supported commands (TS-480 subset)

The subset is chosen so WSJT-X, fldigi, Hamlib (`TS-480` backend), and similar
can drive QMX. Confirm exact support in the QMX CAT PDF for your firmware.

| Op | Function | Notes |
|----|----------|-------|
| `ID` | Radio ID | TS-480 replies `ID020;`. QMX identifies as TS-480-compatible. |
| `FA` | VFO-A frequency | **11 digits**, Hz. `FA00014250000;` |
| `FB` | VFO-B frequency | 11 digits, Hz. |
| `FR` | Receive VFO / function | `FR0;`/`FR1;` |
| `FT` | Transmit VFO / function | `FT0;`/`FT1;` (split control) |
| `MD` | Mode | single digit, Kenwood codes (below). `MD3;` = CW. |
| `IF` | Information | Kenwood IF layout (fixed-width, freq + mode + TX flag). |
| `TX` | Transmit (PTT on) | `TX;` keys. |
| `RX` | Receive (PTT off) | `RX;` unkeys. **← recommended `SET_FAILSAFE` payload.** |
| `PS` | Power status | `PS1;` on. |
| `AI` | Auto-information | `AI0;`/`AI2;` |
| `KS` | Keyer speed (WPM) | CW speed for `KY`. |
| `KY` | CW keying — send text | initiates CW send at current WPM; see below. |
| `RD`/`RU` | RIT down / up | if RIT supported. |
| `SM` | S-meter read | `SM0;` → level. |
| `PC` | Output power | may be fixed/limited on QMX. |
| `SP`/`RT`/`XT` | split / RIT / XIT | as available. |

QMX-specific additions/exceptions exist (QRP Labs notes "one or two"); the CAT
PDF is authoritative. WSJT-X's TS-480 profile is the practical compatibility bar.

## `MD` — mode codes (Kenwood)

Single digit, `MD<code>;`:

| Code | Mode | Code | Mode |
|------|------|------|------|
| `1` | LSB | `6` | FSK / RTTY |
| `2` | USB | `7` | CW-R |
| `3` | CW | `9` | FSK-R / RTTY-R |
| `4` | FM | | |
| `5` | AM | | |

(Code `8` is TUNE/PKTUSB on some Kenwood rigs; `≥10` are packet/data modes on
full TS-480 but generally not on QMX. QMX in practice cares about CW / USB /
LSB for its operating modes.)

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
