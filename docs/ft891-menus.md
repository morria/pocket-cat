# Yaesu FT-891 Menu System Reference (with EX CAT mapping)

Sources: **FT-891 Advance Manual** (1806-F, © 2018) — menu list, defaults, and per-item
descriptions — and the **FT-891 CAT Operation Reference Book** (1909-C) — EX command
value encodings and digit counts. Discrepancies between the two official documents are
flagged inline.

## The EX command

Every front-panel menu item `NN-MM` is reachable over CAT as menu number `NNMM`
(each half zero-padded to two digits):

- **Read**: `EXNNMM;` → answer `EXNNMM<value>;`
- **Set**: `EXNNMM<value>;`

Rules:

- P1 (menu number) is always **4 digits**, range `0101`–`1803`.
- P2 (value) has a **fixed digit count per item** (the "P2 format" column below), always
  zero-padded. Signed items include a literal `+` or `-` (a `-00`/`+00` distinction
  exists for zero).
- Most items store an **index**, not the displayed value (e.g. `EX0506` stores `0`–`3`
  for 4800/9600/19200/38400 bps; the low/high-cut filters store 2-digit step indexes).
  The encoding column below gives the exact mapping.
- All 159 items are listed in the CAT reference EX table and are readable via CAT.
  All are writable except: **18-01/18-02/18-03 (versions — read-only)**, and
  **17-01 RESET**, which is listed with values 0/1/2 but *writing it performs a radio
  reset* — treat as an action, not a setting. Whether the radio accepts an EX Set while
  the operator is inside the front-panel menu (`RS1;`) is undocumented.
- Menu count: 159 items in 18 groups (01 AGC … 18 VERSION).

Shared filter encodings used by the MODE groups:

- **LCUT FREQ** (2 digits): `00` = OFF; `01`–`19` = 100–1000 Hz in 50 Hz steps
  (code = (Hz − 100)/50 + 1).
- **HCUT FREQ** (2 digits): `00` = OFF; `01`–`67` = 700–4000 Hz in 50 Hz steps
  (code = (Hz − 700)/50 + 1).
- **SLOPE** (1 digit): `0` = 6 dB/oct, `1` = 18 dB/oct.
- **MIC/IN SELECT** (1 digit): `0` = MIC (front jack), `1` = REAR (RTTY/DATA jack).
- **PTT SELECT** (1 digit): `0` = DAKY (RTTY/DATA jack pin 3), `1` = RTS, `2` = DTR
  (USB virtual COM lines).
- **OUT/GAIN levels** (3 digits): `000`–`100`.

---

## 01 — AGC (3 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 01-01 | AGC FAST DELAY | AGC fast decay time | Hold-to-decay time of the AGC voltage when AGC is set to FAST. | 20–4000 ms, 20 ms steps (**300 ms**) | `EX0101` — 4 digits, `0020`–`4000` (ms) |
| 01-02 | AGC MID DELAY | AGC mid decay time | Hold-to-decay time of the AGC voltage when AGC is set to MID. | 20–4000 ms, 20 ms steps (**700 ms**) | `EX0102` — 4 digits, `0020`–`4000` (ms) |
| 01-03 | AGC SLOW DELAY | AGC slow decay time | Hold-to-decay time of the AGC voltage when AGC is set to SLOW. | 20–4000 ms, 20 ms steps (**3000 ms**) | `EX0103` — 4 digits, `0020`–`4000` (ms) |

## 02 — DISPLAY (7 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 02-01 | LCD CONTRAST | Display contrast | Sets the LCD contrast level. | 1–15 (**8**) | `EX0201` — 2 digits, `01`–`15` |
| 02-02 | DIMMER BACKLIT | Key backlight brightness | Sets the brightness of the key LEDs. | 1–15 (**8**) | `EX0202` — 2 digits, `01`–`15` |
| 02-03 | DIMMER LCD | LCD brightness | Sets the brightness of the LCD backlight. | 1–15 (**8**) | `EX0203` — 2 digits, `01`–`15` |
| 02-04 | DIMMER TX/BUSY | TX/BUSY LED brightness | Sets the brightness of the TX/BUSY indicator. | 1–15 (**8**) | `EX0204` — 2 digits, `01`–`15` |
| 02-05 | PEAK HOLD | Meter peak hold | How long the meter holds its maximum reading. | OFF/0.5/1.0/2.0 s (**OFF**) | `EX0205` — 1 digit: `0` OFF, `1` 0.5 s, `2` 1.0 s, `3` 2.0 s |
| 02-06 | ZIN LED | CW zero-in LED | Enables the TX/BUSY LED as a CW tuning (zero-in) indicator. | ENABLE/DISABLE (**DISABLE**) | `EX0206` — 1 digit: `0` DISABLE, `1` ENABLE |
| 02-07 | POP-UP MENU | Pop-up position | Sets whether pop-up screens appear in the upper or lower display area. | UPPER/LOWER (**LOWER**) | `EX0207` — 1 digit: `0` UPPER, `1` LOWER |

## 03 — DVS (2 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 03-01 | DVS RX OUT LVL | Voice memory monitor level | Playback/monitoring volume of the recorded voice memories. | 0–100 (**50**) | `EX0301` — 3 digits, `000`–`100` |
| 03-02 | DVS TX OUT LVL | Voice memory TX level | Microphone-output (transmit) level of the voice memories. | 0–100 (**50**) | `EX0302` — 3 digits, `000`–`100` |

## 04 — KEYER (11 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 04-01 | KEYER TYPE | Keyer type | Selects the electronic keyer emulation used with a paddle. | OFF/BUG/ELEKEY-A/ELEKEY-B/ELEKEY-Y/ACS (**ELEKEY-B**) | `EX0401` — 1 digit: `0` OFF, `1` BUG, `2` ELEKEY-A, `3` ELEKEY-B, `4` ELEKEY-Y, `5` ACS |
| 04-02 | KEYER DOT/DASH | Paddle polarity | Normal or reversed dot/dash paddle connections. | NOR/REV (**NOR**) | `EX0402` — 1 digit: `0` NOR, `1` REV |
| 04-03 | CW WEIGHT | CW weight | Dot:dash weighting ratio of the built-in keyer. | 2.5–4.5 (**3.0**) | `EX0403` — 2 digits, `25`–`45` (ratio × 10) |
| 04-04 | BEACON INTERVAL | Beacon repeat interval | Repeat interval for CW beacon message transmission (OFF disables). | OFF / 1–240 s (1 s steps) / 270–690 s (30 s steps) (**OFF**) | `EX0404` — 3 digits, `000`–`690`; `000` = OFF |
| 04-05 | NUMBER STYLE | Contest number style | Morse "cut number" abbreviation style for the contest serial number. | 1290/AUNO/AUNT/A2NO/A2NT/12NO/12NT (**1290**) | `EX0405` — 1 digit: `0`–`6` in listed order |
| 04-06 | CONTEST NUMBER | Contest serial number | Current contest QSO serial number sent by the keyer. | 0–9999 (**1**) | `EX0406` — 4 digits, `0000`–`9999` |
| 04-07 | CW MEMORY 1 | CW memory 1 type | Message keyer slot 1 stores typed TEXT or a paddle-recorded MESSAGE. | TEXT/MESSAGE (**TEXT**) | `EX0407` — 1 digit: `0` TEXT, `1` MESSAGE |
| 04-08 | CW MEMORY 2 | CW memory 2 type | Same as 04-07 for slot 2. | TEXT/MESSAGE (**TEXT**) | `EX0408` — 1 digit: `0`/`1` |
| 04-09 | CW MEMORY 3 | CW memory 3 type | Same as 04-07 for slot 3. | TEXT/MESSAGE (**TEXT**) | `EX0409` — 1 digit: `0`/`1` |
| 04-10 | CW MEMORY 4 | CW memory 4 type | Same as 04-07 for slot 4. | TEXT/MESSAGE (**TEXT**) | `EX0410` — 1 digit: `0`/`1` |
| 04-11 | CW MEMORY 5 | CW memory 5 type | Same as 04-07 for slot 5. | TEXT/MESSAGE (**TEXT**) | `EX0411` — 1 digit: `0`/`1` |

## 05 — GENERAL (20 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 05-01 | NB WIDTH | Noise blanker width | Blanking pulse duration for the noise blanker. | 1/3/10 ms (**3 ms**) | `EX0501` — 1 digit: `0` 1 ms, `1` 3 ms, `2` 10 ms |
| 05-02 | NB REJECTION | Noise blanker rejection | Attenuation depth applied to blanked noise. | 10/30/50 dB (**30 dB**) | `EX0502` — 1 digit: `0` 10, `1` 30, `2` 50 dB |
| 05-03 | NB LEVEL | Noise blanker level | Threshold level of the noise blanker. | 0–10 (**5**) | `EX0503` — 2 digits, `00`–`10` |
| 05-04 | BEEP LEVEL | Beep volume | Key-beep loudness. | 0–100 (**30**) | `EX0504` — 3 digits, `000`–`100` |
| 05-05 | RF/SQL VR | RF/SQL knob function | Selects whether the RF/SQL knob controls RF gain or squelch. | RF/SQL (**RF**) | `EX0505` — 1 digit: `0` RF, `1` SQL |
| 05-06 | CAT RATE | CAT baud rate | Serial speed of the CAT interface. | 4800/9600/19200/38400 bps (**4800**) | `EX0506` — 1 digit: `0` 4800, `1` 9600, `2` 19200, `3` 38400 |
| 05-07 | CAT TOT | CAT timeout | Time-out timer for incomplete CAT command input. | 10/100/1000/3000 ms (**10 ms**) | `EX0507` — 1 digit: `0`–`3` in listed order |
| 05-08 | CAT RTS | CAT RTS handshake | Enables monitoring of the host's RTS line on the CAT port. | ENABLE/DISABLE (**ENABLE**) | `EX0508` — 1 digit: `0` DISABLE, `1` ENABLE |
| 05-09 | MEM GROUP | Memory groups | Divides the 99 memories into 6 groups. | ENABLE/DISABLE (**DISABLE**) | `EX0509` — 1 digit: `0` DISABLE, `1` ENABLE |
| 05-10 | FM SETTING | FM setting screen | Shows/hides the FM SETTING function screen. | ENABLE/DISABLE (**DISABLE**) | `EX0510` — 1 digit: `0`/`1` |
| 05-11 | REC SETTING | REC setting screen | Shows/hides the REC SETTING function screen. | ENABLE/DISABLE (**DISABLE**) | `EX0511` — 1 digit: `0`/`1` |
| 05-12 | ATAS SETTING | ATAS setting screen | Shows/hides the ATAS manual-tuning function screen. | ENABLE/DISABLE (**DISABLE**) | `EX0512` — 1 digit: `0`/`1` |
| 05-13 | QUICK SPL FREQ | Quick-split offset | TX offset applied by the Quick Split (QS) function. | −20…+20 kHz (**+5 kHz**) | `EX0513` — 3 chars: sign + 2 digits, `-20`…`+20` (kHz) |
| 05-14 | TX TOT | TX time-out timer | Maximum continuous transmit time before forced RX. | OFF / 1–30 min (**OFF**; 10 min EU version) | `EX0514` — 2 digits, `00`–`30`; `00` = OFF |
| 05-15 | MIC SCAN | Mic scan | Enables auto-scan started from the microphone UP/DWN keys. | ENABLE/DISABLE (**ENABLE**) | `EX0515` — 1 digit: `0` DISABLE, `1` ENABLE |
| 05-16 | MIC SCAN RESUME | Scan resume mode | Whether scan pauses on a signal or resumes after 5 s. | PAUSE/TIME (**TIME**) | `EX0516` — 1 digit: `0` PAUSE, `1` TIME |
| 05-17 | REF FREQ ADJ | Reference oscillator adjust | Calibrates the master reference oscillator. | −25…+25 (**0**) | `EX0517` — 3 chars: sign + 2 digits, `-25`…`+25` |
| 05-18 | CLAR SELECT | Clarifier mode | Whether the clarifier shifts RX, TX, or both. | RX/TX/TRX (**RX**) | `EX0518` — 1 digit: `0` RX, `1` TX, `2` TRX |
| 05-19 | APO | Auto power off | Powers the radio off after the selected idle time. | OFF/1/2/4/6/8/10/12 h (**OFF**) | `EX0519` — 1 digit: `0` OFF, `1`–`7` = 1/2/4/6/8/10/12 h |
| 05-20 | FAN CONTROL | Fan profile | Normal or aggressive (contest) cooling-fan behavior. | NORMAL/CONTEST (**NORMAL**) | `EX0520` — 1 digit: `0` NORMAL, `1` CONTEST |

## 06 — MODE AM (7 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 06-01 | AM LCUT FREQ | AM RX low-cut frequency | Low-frequency cutoff of the AM receive audio filter. | OFF / 100–1000 Hz, 50 Hz steps (**OFF**) | `EX0601` — 2 digits, LCUT encoding |
| 06-02 | AM LCUT SLOPE | AM low-cut slope | Slope of the AM low-cut filter. | 6/18 dB/oct (**6 dB/oct**) | `EX0602` — 1 digit, SLOPE |
| 06-03 | AM HCUT FREQ | AM RX high-cut frequency | High-frequency cutoff of the AM receive audio filter. | 700–4000 Hz / OFF, 50 Hz steps (**OFF**) | `EX0603` — 2 digits, HCUT encoding |
| 06-04 | AM HCUT SLOPE | AM high-cut slope | Slope of the AM high-cut filter. | 6/18 dB/oct (**6 dB/oct**) | `EX0604` — 1 digit, SLOPE |
| 06-05 | AM MIC SELECT | AM audio input | Front MIC jack or rear RTTY/DATA jack as AM TX audio source. | MIC/REAR (**MIC**) | `EX0605` — 1 digit, MIC/REAR |
| 06-06 | AM OUT LEVEL | AM rear output level | RX audio level on the RTTY/DATA jack in AM mode. | 0–100 (**50**) | `EX0606` — 3 digits, `000`–`100` |
| 06-07 | AM PTT SELECT | AM PTT source | PTT control line used for AM transmit. | DAKY/RTS/DTR (**DAKY**) | `EX0607` — 1 digit, PTT |

## 07 — MODE CW (13 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 07-01 | CW LCUT FREQ | CW RX low-cut frequency | Low-frequency cutoff of the CW receive audio filter. | OFF / 100–1000 Hz (**250 Hz**) | `EX0701` — 2 digits, LCUT |
| 07-02 | CW LCUT SLOPE | CW low-cut slope | Slope of the CW low-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX0702` — 1 digit, SLOPE |
| 07-03 | CW HCUT FREQ | CW RX high-cut frequency | High-frequency cutoff of the CW receive audio filter. | 700–4000 Hz / OFF (**1200 Hz**) | `EX0703` — 2 digits, HCUT |
| 07-04 | CW HCUT SLOPE | CW high-cut slope | Slope of the CW high-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX0704` — 1 digit, SLOPE |
| 07-05 | CW OUT LEVEL | CW rear output level | RX audio level on the RTTY/DATA jack in CW mode. | 0–100 (**50**) | `EX0705` — 3 digits |
| 07-06 | CW AUTO MODE | CW keying in SSB | Allows CW keying while operating SSB (off / 50 MHz only / all bands). | OFF/50M/ON (**OFF**) | `EX0706` — 1 digit: `0` OFF, `1` 50M, `2` ON |
| 07-07 | CW BFO | CW carrier side | CW carrier injection side (affects MD mode reporting). | USB/LSB/AUTO (**USB**) | `EX0707` — 1 digit: `0` USB, `1` LSB, `2` AUTO |
| 07-08 | CW BK-IN TYPE | Break-in type | Semi or full (QSK) break-in. | SEMI/FULL (**SEMI**) | `EX0708` — 1 digit: `0` SEMI, `1` FULL |
| 07-09 | CW BK-IN DELAY | Semi break-in delay | RX recovery delay after keying in semi break-in (10 ms steps). | 30–3000 ms (**200 ms**) | `EX0709` — 4 digits, `0030`–`3000` |
| 07-10 | CW WAVE SHAPE | Keying envelope | CW carrier rise/fall time. | 2/4 ms (**4 ms**) | `EX0710` — 1 digit: **`1` = 2 ms, `2` = 4 ms** (note: not 0-based) |
| 07-11 | CW FREQ DISPLAY | CW frequency display | Displays carrier frequency or pitch-offset frequency in CW. | FREQ/PITCH (**PITCH**) | `EX0711` — 1 digit: `0` FREQ, `1` PITCH |
| 07-12 | PC KEYING | PC CW keying line | Keying source for computer CW (off / DAKY / RTS / DTR). | OFF/DAKY/RTS/DTR (**OFF**) | `EX0712` — 1 digit: `0` OFF, `1` DAKY, `2` RTS, `3` DTR |
| 07-13 | QSK DELAY TIME | QSK TX delay | Delay before the carrier is transmitted in full break-in. | 15/20/25/30 ms (**15 ms**) | `EX0713` — 1 digit: `0`–`3` in listed order |

## 08 — MODE DATA (12 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 08-01 | DATA MODE | Data scheme | Operating scheme in DATA mode: PSK or other AFSK modes. | PSK/OTHERS (**PSK**) | `EX0801` — 1 digit: `0` PSK, `1` OTHERS |
| 08-02 | PSK TONE | PSK tone frequency | Audio tone frequency used for PSK. | 1000/1500/2000 Hz (**1000 Hz**) | `EX0802` — 1 digit: `0`–`2` in listed order |
| 08-03 | OTHER DISP | Data display offset | Display frequency offset in DATA (OTHERS) mode, 10 Hz steps. | −3000…+3000 Hz (**0 Hz**) | `EX0803` — 5 chars: sign + 4 digits, `-3000`…`+3000` |
| 08-04 | OTHER SHIFT | Data carrier point | Carrier point offset in DATA (OTHERS) mode, 10 Hz steps. | −3000…+3000 Hz (**0 Hz**) | `EX0804` — 5 chars: sign + 4 digits |
| 08-05 | DATA LCUT FREQ | Data RX low-cut frequency | Low-frequency cutoff of the DATA receive audio filter. | OFF / 100–1000 Hz (**300 Hz**) | `EX0805` — 2 digits, LCUT |
| 08-06 | DATA LCUT SLOPE | Data low-cut slope | Slope of the DATA low-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX0806` — 1 digit, SLOPE |
| 08-07 | DATA HCUT FREQ | Data RX high-cut frequency | High-frequency cutoff of the DATA receive audio filter. | 700–4000 Hz / OFF (**3000 Hz**) | `EX0807` — 2 digits, HCUT |
| 08-08 | DATA HCUT SLOPE | Data high-cut slope | Slope of the DATA high-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX0808` — 1 digit, SLOPE |
| 08-09 | DATA IN SELECT | Data audio input | Front MIC jack or rear RTTY/DATA jack as DATA input. | MIC/REAR (**REAR**) | `EX0809` — 1 digit, MIC/REAR |
| 08-10 | DATA PTT SELECT | Data PTT source | PTT control line used for DATA transmit. | DAKY/RTS/DTR (**DAKY**) | `EX0810` — 1 digit, PTT |
| 08-11 | DATA OUT LEVEL | Data output level | Audio output level on the rear jack for data operation. | 0–100 (**50**) | `EX0811` — 3 digits |
| 08-12 | DATA BFO | Data carrier side | DATA carrier injection side (affects MD mode reporting). | USB/LSB (**LSB**) | `EX0812` — 1 digit: `0` USB, `1` LSB |

## 09 — MODE FM (6 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 09-01 | FM MIC SELECT | FM audio input | Front MIC jack or rear RTTY/DATA jack as FM TX audio source. | MIC/REAR (**MIC**) | `EX0901` — 1 digit, MIC/REAR |
| 09-02 | FM OUT LEVEL | FM rear output level | RX audio level on the RTTY/DATA jack in FM mode. | 0–100 (**50**) | `EX0902` — 3 digits |
| 09-03 | PKT PTT SELECT | Packet PTT source | PTT control line used for FM packet transmit. | DAKY/RTS/DTR (**DAKY**) | `EX0903` — 1 digit, PTT |
| 09-04 | RPT SHIFT 28MHz | 28 MHz repeater offset | Repeater shift amount on the 28 MHz band (10 kHz steps). | 0–1000 kHz (**100 kHz**) | `EX0904` — 4 digits, `0000`–`1000` (kHz) |
| 09-05 | RPT SHIFT 50MHz | 50 MHz repeater offset | Repeater shift amount on the 50 MHz band (10 kHz steps). | 0–4000 kHz (**1000 kHz**) | `EX0905` — 4 digits, `0000`–`4000` (kHz). (CAT book's digit column says "1" — a typo; the value range requires 4 digits.) |
| 09-06 | DCS POLARITY | DCS polarity | Normal/inverted DCS code phase for TX and RX. | Tn-Rn/Tn-Riv/Tiv-Rn/Tiv-Riv (**Tn-Rn**) | `EX0906` — 1 digit: `0`–`3` in listed order |

## 10 — MODE RTTY (11 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 10-01 | RTTY LCUT FREQ | RTTY RX low-cut frequency | Low-frequency cutoff of the RTTY receive audio filter. | OFF / 100–1000 Hz (**300 Hz**) | `EX1001` — 2 digits, LCUT |
| 10-02 | RTTY LCUT SLOPE | RTTY low-cut slope | Slope of the RTTY low-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX1002` — 1 digit, SLOPE |
| 10-03 | RTTY HCUT FREQ | RTTY RX high-cut frequency | High-frequency cutoff of the RTTY receive audio filter. | 700–4000 Hz / OFF (**3000 Hz**) | `EX1003` — 2 digits, HCUT |
| 10-04 | RTTY HCUT SLOPE | RTTY high-cut slope | Slope of the RTTY high-cut filter. | 6/18 dB/oct (**18 dB/oct**) | `EX1004` — 1 digit, SLOPE |
| 10-05 | RTTY SHIFT PORT | FSK shift input | Input line used for FSK shift keying. | SHIFT/DTR/RTS (**SHIFT**) | `EX1005` — 1 digit: `0` SHIFT, `1` DTR, `2` RTS |
| 10-06 | RTTY POLARITY-R | RX shift polarity | Mark/space shift direction on receive. | NOR/REV (**NOR**) | `EX1006` — 1 digit: `0` NOR, `1` REV |
| 10-07 | RTTY POLARITY-T | TX shift polarity | Mark/space shift direction on transmit. | NOR/REV (**NOR**) | `EX1007` — 1 digit: `0` NOR, `1` REV |
| 10-08 | RTTY OUT LEVEL | RTTY output level | Audio output level on the rear jack in RTTY mode. | 0–100 (**50**) | `EX1008` — 3 digits |
| 10-09 | RTTY SHIFT FREQ | RTTY shift width | FSK shift width. | 170/200/425/850 Hz (**170 Hz**) | `EX1009` — 1 digit: `0`–`3` in listed order |
| 10-10 | RTTY MARK FREQ | RTTY mark frequency | Mark tone frequency. | 1275/2125 Hz (**2125 Hz**) | `EX1010` — 1 digit: `0` 1275, `1` 2125 |
| 10-11 | RTTY BFO | RTTY carrier side | RTTY carrier injection side (affects MD mode reporting). | USB/LSB (**LSB**) | `EX1011` — 1 digit: `0` USB, `1` LSB |

## 11 — MODE SSB (9 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 11-01 | SSB LCUT FREQ | SSB RX low-cut frequency | Low-frequency cutoff of the SSB receive audio filter. | OFF / 100–1000 Hz (**100 Hz**) | `EX1101` — 2 digits, LCUT |
| 11-02 | SSB LCUT SLOPE | SSB low-cut slope | Slope of the SSB low-cut filter. | 6/18 dB/oct (**6 dB/oct**) | `EX1102` — 1 digit, SLOPE |
| 11-03 | SSB HCUT FREQ | SSB RX high-cut frequency | High-frequency cutoff of the SSB receive audio filter. | 700–4000 Hz / OFF (**3000 Hz**) | `EX1103` — 2 digits, HCUT |
| 11-04 | SSB HCUT SLOPE | SSB high-cut slope | Slope of the SSB high-cut filter. | 6/18 dB/oct (**6 dB/oct**) | `EX1104` — 1 digit, SLOPE |
| 11-05 | SSB MIC SELECT | SSB audio input | Front MIC jack or rear RTTY/DATA jack as SSB TX audio source. | MIC/REAR (**MIC**) | `EX1105` — 1 digit, MIC/REAR |
| 11-06 | SSB OUT LEVEL | SSB rear output level | RX audio level on the RTTY/DATA jack in SSB mode. | 0–100 (**50**) | `EX1106` — 3 digits |
| 11-07 | SSB BFO | SSB carrier side | SSB carrier injection side; AUTO = LSB ≤7 MHz, USB ≥10 MHz. | USB/LSB/AUTO (**AUTO**) | `EX1107` — 1 digit: `0` USB, `1` LSB, `2` AUTO |
| 11-08 | SSB PTT SELECT | SSB PTT source | PTT control line used for SSB transmit. | DAKY/RTS/DTR (**DAKY**) | `EX1108` — 1 digit, PTT |
| 11-09 | SSB TX BPF | SSB TX bandwidth | DSP transmit band-pass filter range in SSB. | 100-3000/100-2900/200-2800/300-2700/400-2600 Hz (**300-2700**) | `EX1109` — 1 digit: `0`–`4` in listed order |

## 12 — RX DSP (4 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 12-01 | APF WIDTH | Audio peak filter width | Bandwidth of the CW audio peak filter. | NARROW/MEDIUM/WIDE (**MEDIUM**) | `EX1201` — 1 digit: `0` NARROW, `1` MEDIUM, `2` WIDE |
| 12-02 | CONTOUR LEVEL | Contour gain | Gain/attenuation depth of the contour circuit. | −40…+20 (**−15**) | `EX1202` — 3 chars: sign + 2 digits, `-40`…`+20` |
| 12-03 | CONTOUR WIDTH | Contour Q | Bandwidth (Q) of the contour circuit. | 1–11 (**10**) | `EX1203` — 2 digits, `01`–`11` |
| 12-04 | IF NOTCH WIDTH | IF notch width | Attenuation bandwidth of the DSP IF notch filter. | NARROW/WIDE (**WIDE**) | `EX1204` — 1 digit: `0` NARROW, `1` WIDE |

## 13 — SCOPE (2 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 13-01 | SCP START CYCLE | Scope sweep interval | Auto-repeat interval of the spectrum-scope sweep. | OFF/3/5/10 s (**OFF**) | `EX1301` — 1 digit: `0` OFF, `1` 3 s, `2` 5 s, `3` 10 s |
| 13-02 | SCP SPAN FREQ | Scope span | Frequency span of the spectrum scope. | 37.5/75/150/375/750 kHz (**750 kHz**) | `EX1302` — 2 digits, `00`–`04` in listed order **[HW-VERIFIED 2026-07-27: real rig answers 2 digits; the CAT book table says 1]** |

## 14 — TUNING (7 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 14-01 | QUICK DIAL | MULTI knob step | MULTI-knob tuning step in SSB/CW/RTTY/DATA. | 50/100/500 kHz (**500 kHz**) | `EX1401` — 1 digit: `0` 50, `1` 100, `2` 500 kHz |
| 14-02 | SSB DIAL STEP | SSB dial step | Main dial step in SSB. | 2/5/10 Hz (**10 Hz**) | `EX1402` — 1 digit: `0` 2, `1` 5, `2` 10 Hz |
| 14-03 | AM DIAL STEP | AM dial step | Main dial step in AM. | 10/100 Hz (**10 Hz**) | `EX1403` — 1 digit: `0` 10, `1` 100 Hz |
| 14-04 | FM DIAL STEP | FM dial step | Main dial step in FM. | 10/100 Hz (**100 Hz**) | `EX1404` — 1 digit: `0` 10, `1` 100 Hz |
| 14-05 | DIAL STEP | CW/RTTY/DATA dial step | Main dial step (non-SSB/AM/FM modes). | 2/5/10 Hz (**5 Hz**) | `EX1405` — 1 digit: `0` 2, `1` 5, `2` 10 Hz |
| 14-06 | AM CH STEP | AM channel step | MULTI-knob / mic UP-DWN channel step in AM. | 2.5/5/9/10/12.5/25 kHz (**2.5 kHz** per item description; the manual's summary table says 5 kHz — discrepancy in the official manual) | `EX1406` — 1 digit: `0`–`5` in listed order |
| 14-07 | FM CH STEP | FM channel step | MULTI-knob / mic UP-DWN channel step in FM. | 5/6.25/10/12.5/15/20/25 kHz (**5 kHz**) | `EX1407` — 1 digit: `0`–`6` in listed order |

## 15 — TX AUDIO (18 items)

Three-band parametric microphone equalizer. Items 15-01…15-09 apply with the speech
processor OFF; 15-10…15-18 ("P-EQ") apply when the speech processor is ON.

Frequency encodings (2 digits): EQ1/P-EQ1: `00` OFF, `01`–`07` = 100–700 Hz (100 Hz
steps). EQ2/P-EQ2: `00` OFF, `01`–`09` = 700–1500 Hz. EQ3/P-EQ3: `00` OFF,
`01`–`18` = 1500–3200 Hz (100 Hz steps).

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 15-01 | EQ1 FREQ | EQ low band frequency | Center frequency of the low EQ band. | OFF/100–700 Hz (**OFF**) | `EX1501` — 2 digits, `00`–`07` |
| 15-02 | EQ1 LEVEL | EQ low band gain | Gain of the low EQ band. | −20…+10 dB (**+5**) | `EX1502` — 3 chars: sign + 2 digits, `-20`…`+10` |
| 15-03 | EQ1 BWTH | EQ low band Q | Bandwidth (Q) of the low EQ band. | 1–10 (**10**) | `EX1503` — 2 digits, `01`–`10` |
| 15-04 | EQ2 FREQ | EQ mid band frequency | Center frequency of the mid EQ band. | OFF/700–1500 Hz (**OFF**) | `EX1504` — 2 digits, `00`–`09` |
| 15-05 | EQ2 LEVEL | EQ mid band gain | Gain of the mid EQ band. | −20…+10 dB (**+5**) | `EX1505` — 3 chars: sign + 2 digits |
| 15-06 | EQ2 BWTH | EQ mid band Q | Bandwidth (Q) of the mid EQ band. | 1–10 (**10**) | `EX1506` — 2 digits |
| 15-07 | EQ3 FREQ | EQ high band frequency | Center frequency of the high EQ band. | OFF/1500–3200 Hz (**OFF**) | `EX1507` — 2 digits, `00`–`18` |
| 15-08 | EQ3 LEVEL | EQ high band gain | Gain of the high EQ band. | −20…+10 dB (**+5**) | `EX1508` — 3 chars: sign + 2 digits |
| 15-09 | EQ3 BWTH | EQ high band Q | Bandwidth (Q) of the high EQ band. | 1–10 (**10**) | `EX1509` — 2 digits |
| 15-10 | P-EQ1 FREQ | Proc EQ low frequency | Low EQ band center with speech processor on. | OFF/100–700 Hz (**200 Hz**) | `EX1510` — 2 digits, `00`–`07` |
| 15-11 | P-EQ1 LEVEL | Proc EQ low gain | Low EQ band gain with speech processor on. | −20…+10 dB (**0**) | `EX1511` — 3 chars: sign + 2 digits |
| 15-12 | P-EQ1 BWTH | Proc EQ low Q | Low EQ band Q with speech processor on. | 1–10 (**2**) | `EX1512` — 2 digits |
| 15-13 | P-EQ2 FREQ | Proc EQ mid frequency | Mid EQ band center with speech processor on. | OFF/700–1500 Hz (**800 Hz**) | `EX1513` — 2 digits, `00`–`09` |
| 15-14 | P-EQ2 LEVEL | Proc EQ mid gain | Mid EQ band gain with speech processor on. | −20…+10 dB (**0**) | `EX1514` — 3 chars: sign + 2 digits |
| 15-15 | P-EQ2 BWTH | Proc EQ mid Q | Mid EQ band Q with speech processor on. | 1–10 (**1**) | `EX1515` — 2 digits |
| 15-16 | P-EQ3 FREQ | Proc EQ high frequency | High EQ band center with speech processor on. | OFF/1500–3200 Hz (**2100 Hz**) | `EX1516` — 2 digits, `00`–`18` |
| 15-17 | P-EQ3 LEVEL | Proc EQ high gain | High EQ band gain with speech processor on. | −20…+10 dB (**0**) | `EX1517` — 3 chars: sign + 2 digits |
| 15-18 | P-EQ3 BWTH | Proc EQ high Q | High EQ band Q with speech processor on. | 1–10 (**1**) | `EX1518` — 2 digits |

## 16 — TX GENERAL (23 items)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 16-01 | HF SSB PWR | HF SSB power | Max TX power for SSB on HF. | 5–100 W (**100**) | `EX1601` — 3 digits, `005`–`100` |
| 16-02 | HF AM PWR | HF AM power | Max TX (carrier) power for AM on HF. | 5–40 W (**25**) | `EX1602` — 3 digits, `005`–`040` |
| 16-03 | HF PWR | HF power (CW/data/FM) | Max TX power on HF for all other modes. | 5–100 W (**100**) | `EX1603` — 3 digits, `005`–`100` |
| 16-04 | 50M SSB PWR | 6 m SSB power | Max TX power for SSB on 50 MHz. | 5–100 W (**100**) | `EX1604` — 3 digits |
| 16-05 | 50M AM PWR | 6 m AM power | Max TX (carrier) power for AM on 50 MHz. | 5–40 W (**25**) | `EX1605` — 3 digits, `005`–`040` |
| 16-06 | 50M PWR | 6 m power (CW/data/FM) | Max TX power on 50 MHz for all other modes. | 5–100 W (**100**) | `EX1606` — 3 digits |
| 16-07 | SSB MIC GAIN | SSB mic gain | Microphone gain in SSB mode. | 0–100 (**30** per item description; summary table says 50 — discrepancy in the official manual) | `EX1607` — 3 digits, `000`–`100` |
| 16-08 | AM MIC GAIN | AM mic gain | Microphone gain in AM mode. | 0–100 (**30** per item description; summary table says 50 — discrepancy) | `EX1608` — 3 digits |
| 16-09 | FM MIC GAIN | FM mic gain | Microphone gain in FM mode. | 0–100 (**50**) | `EX1609` — 3 digits |
| 16-10 | DATA MIC GAIN | Data AFSK input gain | Input level from the TNC to the AFSK modulator. | 0–100 (**50**) | `EX1610` — 3 digits |
| 16-11 | SSB DATA GAIN | SSB rear input gain | Rear-jack input level when SSB MIC SELECT = REAR. | 0–100 (**50**) | `EX1611` — 3 digits |
| 16-12 | AM DATA GAIN | AM rear input gain | Rear-jack input level when AM MIC SELECT = REAR. | 0–100 (**50**) | `EX1612` — 3 digits |
| 16-13 | FM DATA GAIN | FM rear input gain | Rear-jack input level when FM MIC SELECT = REAR. | 0–100 (**50**) | `EX1613` — 3 digits |
| 16-14 | DATA DATA GAIN | Data rear input gain | Rear-jack input level when DATA IN SELECT = REAR. | 0–100 (**50**) | `EX1614` — 3 digits |
| 16-15 | TUNER SELECT | Tuner/amp selection | Selects the attached tuner (FC-40/FC-50), ATAS antenna, or linear-amp control on the TUN/LIN jack. Required for `AC002;` tune to work. | OFF/EXTERNAL/ATAS/LAMP (**OFF**) | `EX1615` — 1 digit: `0` OFF, `1` EXTERNAL, `2` ATAS, `3` LAMP |
| 16-16 | VOX SELECT | VOX source | VOX triggers from the mic or from rear-jack data audio. | MIC/DATA (**MIC**) | `EX1616` — 1 digit: `0` MIC, `1` DATA |
| 16-17 | VOX GAIN | VOX gain | Sensitivity of the VOX circuit (also via `VG` command). | 0–100 (**50**) | `EX1617` — 3 digits |
| 16-18 | VOX DELAY | VOX delay | Hang time before returning to RX (10 ms steps; also via `VD`). | 30–3000 ms (**500 ms**) | `EX1618` — 4 digits, `0030`–`3000` |
| 16-19 | ANTI VOX GAIN | Anti-VOX gain | Prevents speaker audio from tripping VOX. | 0–100 (**50**) | `EX1619` — 3 digits |
| 16-20 | DATA VOX GAIN | Data VOX gain | VOX sensitivity for data-audio input. | 0–100 (**50**) | `EX1620` — 3 digits |
| 16-21 | DATA VOX DELAY | Data VOX delay | VOX hang time for data operation. | 30–3000 ms (**100 ms**) | `EX1621` — 4 digits, `0030`–`3000` |
| 16-22 | ANTI DVOX GAIN | Data anti-VOX gain | Prevents received data audio from tripping data VOX. | 0–100 (**0**) | `EX1622` — 3 digits |
| 16-23 | EMERGENCY FREQ | Alaska emergency channel | Enables TX/RX on 5167.5 kHz (Alaska emergency use only). | ENABLE/DISABLE (**DISABLE**) | `EX1623` — 1 digit: `0` DISABLE, `1` ENABLE |

## 17 — RESET (1 item)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 17-01 | RESET | Radio reset | Performs a reset: ALL (factory, clears memories), DATA (clears memories only), or FUNC (menu/function keys only). | ALL/DATA/FUNC (no default) | `EX1701` — 1 digit: `0` ALL, `1` DATA, `2` FUNC. **Action, not a setting — writing it resets the radio.** Behavior when written via CAT is listed but the manual gives no further detail. |

## 18 — VERSION (3 items, read-only)

| # | Official name | Friendly name | What it does | Values (default) | EX / P2 format |
|---|---------------|---------------|--------------|------------------|----------------|
| 18-01 | MAIN VERSION | Main firmware version | Displays the main CPU firmware version. | display only | `EX1801;` read → 4 digits (`0123` = V01-23). Read-only. |
| 18-02 | DSP VERSION | DSP firmware version | Displays the DSP firmware version. | display only | `EX1802;` read → 4 digits. Read-only. |
| 18-03 | LCD VERSION | LCD firmware version | Displays the front-panel LCD firmware version. | display only | `EX1803;` read → 4 digits. Read-only. |

---

## Implementation notes

1. **Item count**: 3+7+2+11+20+7+13+12+6+11+9+4+2+7+18+23+1+3 = **159 items**.
2. **Read/write via CAT**: everything is readable; 18-xx are read-only; 17-01 is a
   destructive action. All other items are settable via `EXNNMM<value>;` per the CAT
   reference EX table.
3. **Signed values** (`EX0513`, `EX0517`, `EX0803`, `EX0804`, `EX1202`, `EX1502/05/08`,
   `EX1511/14/17`): always include the sign character; zero may be `+00`/`-00`
   (or `+0000`/`-0000` for the 5-char items).
4. **Index-coded items**: for UI work, keep a per-item value↔label map; the radio
   stores/returns the index (left column of each encoding), not the display value.
5. **Menu numbers with no CAT quirks** otherwise map 1:1 (`05-06` ↔ `EX0506`).
6. **Official-manual discrepancies** (summary table vs per-item description in the
   Advance Manual): 14-06 AM CH STEP default (5 kHz vs 2.5 kHz), 16-07/16-08 mic gain
   defaults (50 vs 30). Verify against a live radio if defaults matter; the per-item
   descriptions are believed more reliable.
7. Changes made via EX take effect immediately; no "save" command is needed (the
   front-panel save step applies to knob editing, not CAT). **[UNVERIFIED — community
   experience]**
