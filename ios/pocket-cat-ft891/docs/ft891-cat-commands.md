# Yaesu FT-891 CAT Command Reference

Source of truth: **FT-891 CAT Operation Reference Book** (Yaesu, doc no. 1909-C, © 2019),
cross-checked against the FT-891 Advance Manual (1806-F) and the hamlib `rigs/yaesu/ft891.c`
backend. Items not stated in the official manual are marked **[UNVERIFIED]** or
**[COMMUNITY]** (widely reported but not in the manual).

---

## 1. Serial protocol basics

- **Physical**: Rear-panel USB jack. The radio contains a built-in *USB to Dual UART bridge*
  (Silicon Labs CP210x dual-port). Two virtual COM ports appear on the host:
  the **Enhanced COM port carries CAT**; the Standard COM port carries the RTS/DTR
  PTT/keying/FSK lines selected by menus (e.g. 07-12 PC KEYING, 08-10 DATA PTT SELECT).
  **[COMMUNITY]** (the dual-UART bridge itself is stated in the manual; which port is
  which is community knowledge, e.g. digirig/WSJT-X setup guides).
- **Baud rate**: 4800 (factory default) / 9600 / 19200 / 38400 bps — menu **05-06 CAT RATE**
  (`EX0506`, values 0–3).
- **Framing**: 8 data bits, no parity, **2 stop bits assumed** — the manual does not state
  framing; hamlib uses 8N2 ("assumed since manual makes no mention"). 8N1 also works for
  many users. **[UNVERIFIED]**
- **Flow control**: RTS monitoring can be disabled with menu **05-08 CAT RTS**
  (`EX0508`; default ENABLE). If your USB/serial stack does not assert RTS, either assert
  it or set CAT RTS to DISABLE, otherwise the radio may ignore CAT input. **[COMMUNITY]**
- **CAT timeout**: menu **05-07 CAT TOT** (`EX0507`, 10/100/1000/3000 ms, default 10 ms)
  is the time-out timer for partially received commands.
- **Character set**: plain ASCII. Commands are two alphabetic characters,
  **upper or lower case both accepted**.
- **Terminator**: every command and every answer ends with a semicolon `;`.
- **Three command forms**:
  - **Set** — `FA014250000;` (host → radio: set a condition)
  - **Read** — `FA;` (host → radio: request a value)
  - **Answer** — `FA014250000;` (radio → host: reply to a Read, or an AI-mode push)
- **Parameter rules** (from the manual): every parameter has a fixed, predetermined digit
  count. Too few digits, too many digits, missing sign characters, or stray characters
  between parameters make the command invalid. Signed parameters carry an explicit
  `+`/`-` character in a fixed position. Unused/not-applicable parameter positions must
  still be filled (any character except ASCII control codes 00–1F and `;`).
- **Error response**: the radio answers an invalid or unreadable command with `?;`.
  **[COMMUNITY]** (standard Yaesu behavior; not spelled out in the FT-891 book).
- **AI (Auto Information) mode**: `AI1;` makes the radio push Answer messages
  automatically whenever a state marked "AI: O" in the table below changes.
  **AI is forced back to 0 (OFF) whenever the radio is powered off** (stated in manual).
- **Menu mode**: `RS;` reports whether the radio is in normal (`RS0;`) or front-panel
  menu mode (`RS1;`). Poll this before pushing settings; behavior of Set commands while
  the operator is inside the menu is not documented. **[UNVERIFIED]**

---

## 2. Command index

Complete FT-891 command set (60 commands). O = supported, X = not supported.
"AI" = the radio pushes this answer automatically in AI mode.

| Cmd | Function | Set | Read | Ans | AI |
|-----|----------|-----|------|-----|----|
| AB | VFO-A → VFO-B copy | O | X | X | X |
| AC | Antenna tuner control | O | O | O | O |
| AG | AF gain | O | O | O | O |
| AI | Auto information | O | O | O | X |
| AM | VFO-A → memory channel | O | X | X | X |
| BA | VFO-B → VFO-A copy | O | X | X | X |
| BC | Auto notch (DNF) | O | O | O | O |
| BD | Band down | O | X | X | X |
| BI | Break-in | O | O | O | O |
| BP | Manual notch | O | O | O | O |
| BS | Band select | O | X | X | X |
| BU | Band up | O | X | X | X |
| BY | Busy | X | O | O | O |
| CF | Clarifier on/off | O | O | O | O |
| CH | Memory channel up/down | O | X | X | X |
| CN | CTCSS/DCS number | O | O | O | O |
| CO | Contour / APF | O | O | O | O |
| CS | CW spot | O | O | O | O |
| CT | CTCSS mode | O | O | O | O |
| DA | Dimmer | O | O | O | X |
| DN | Mic [DWN] | O | X | X | X |
| ED | Encoder down | O | X | X | X |
| EK | ENT key | O | X | X | X |
| EU | Encoder up | O | X | X | X |
| EX | Menu | O | O | O | O |
| FA | VFO-A frequency | O | O | O | X |
| FB | VFO-B frequency | O | O | O | X |
| FS | Fast step | O | O | O | O |
| GT | AGC function | O | O | O | O |
| ID | Identification | X | O | O | X |
| IF | Information (composite) | X | O | O | O |
| IS | IF shift | O | O | O | O |
| KM | Keyer memory (text) | O | O | O | X |
| KP | Key (CW) pitch | O | O | O | O |
| KR | Keyer on/off | O | O | O | O |
| KS | Key speed | O | O | O | O |
| KY | CW keying (memory playback) | O | X | X | X |
| LK | Dial lock | O | O | O | O |
| LM | Load message (DVS record) | O | O | O | X |
| MA | Memory channel → VFO-A | O | X | X | X |
| MC | Memory channel select | O | O | O | X |
| MD | Operating mode | O | O | O | O |
| MG | Mic gain | O | O | O | O |
| ML | Monitor level | O | O | O | O |
| MR | Memory channel read | X | O | O | X |
| MS | Meter switch | O | O | O | O |
| MT | Memory write & tag | O | O* | O* | X |
| MW | Memory channel write | O | X | X | X |
| MX | MOX set | O | O | O | O |
| NA | Narrow filter | O | O | O | O |
| NB | Noise blanker on/off | O | O | O | O |
| NL | Noise blanker level | O | O | O | O |
| NR | Noise reduction (DNR) on/off | O | O | O | O |
| OI | Opposite band information | X | O | O | O |
| OS | Offset (repeater shift) | O | O | O | O |
| PA | Pre-amp (IPO/AMP) | O | O | O | O |
| PB | Play back (DVS) | O | O | O | X |
| PC | Power control (TX power) | O | O | O | O |
| PL | Speech processor level | O | O | O | O |
| PR | Speech processor on/off | O | O | O | O |
| PS | Power switch | O | O | O | X |
| QI | QMB store | O | X | X | X |
| QR | QMB recall | O | X | X | X |
| QS | Quick split | O | X | X | X |
| RA | RF attenuator | O | O | O | O |
| RC | Clarifier clear | O | X | X | X |
| RD | Clarifier down | O | X | X | X |
| RG | RF gain | O | O | O | O |
| RI | Radio information (LED/status) | X | O | O | O |
| RL | Noise reduction level | O | O | O | O |
| RM | Read meter | X | O | O | O |
| RS | Radio status (menu mode) | X | O | O | O |
| RU | Clarifier up | O | X | X | X |
| SC | Scan | O | O | O | O |
| SD | Semi break-in delay time | O | O | O | O |
| SH | Width (DSP bandwidth) | O | O | O | O |
| SM | S-meter | X | O | O | X |
| SQ | Squelch level | O | O | O | O |
| ST | Split | O | O | O | O |
| SV | Swap VFO (A↔B) | O | X | X | X |
| TS | TXW (transmit watch) | O | O | O | O |
| TX | TX set (CAT PTT) | O | O | O | O |
| UL | PLL unlock status | X | O | O | O |
| UP | Mic [UP] | O | X | X | X |
| VD | VOX delay time | O | O | O | O |
| VG | VOX gain | O | O | O | O |
| VM | [V/M] key (VFO-A → memory ch.) | O | X | X | X |
| VX | VOX on/off | O | O | O | O |
| ZI | Zero in (CW auto zero-beat) | O | X | X | X |

\* MT read takes a channel argument (`MTnnn;`) and answers with the full record.

**Commands that exist on the FT-991 but NOT on the FT-891** (do not send these):
`FR`/`FT` (RX/TX VFO select — the FT-891 uses **ST** for split), `DT` (date/time),
`SS` (scope), `AN` (antenna select), `MN`, `BM`, `PL`→(exists), `VT`, `XT`
(TX clarifier — on the FT-891 TX-clar is a menu setting, 05-18 CLAR SELECT).
Anything not in the table above is unsupported.

---

## 3. Command details by function

Notation: literal digits are shown as-is; `P1 P2 …` are parameters with the digit counts
given. All commands end with `;`.

### 3.1 Frequency and band

#### FA — VFO-A frequency
- Set: `FA` + 9 digits + `;` — frequency in **Hz, 9 digits, zero-padded**.
  Range `000030000`–`056000000` (30 kHz – 56 MHz). Example: `FA014250000;` = 14.250000 MHz.
- Read: `FA;` → Answer: `FA014250000;`

#### FB — VFO-B frequency
- Same format as FA: `FB` + 9 digits + `;`. Range `000030000`–`056000000`.

#### BS — Band select (set only)
- Set: `BSnn;` (2 digits):
  `00`=1.8 MHz, `01`=3.5, `02`=(unused), `03`=7, `04`=10, `05`=14, `06`=18, `07`=21,
  `08`=24.5, `09`=28, `10`=50, `11`=GEN, `12`=MW.
  (There is no 5 MHz band code; 60 m is via the fixed 5xx memory channels.)

#### BU / BD — Band up / band down (set only)
- Set: `BU0;` / `BD0;` (P1 is fixed `0`).

#### UP / DN — Mic [UP]/[DWN] key emulation (set only)
- Set: `UP;` / `DN;` — steps the frequency as the microphone keys do.

#### EU / ED — Encoder up / down (set only)
- Set: `EUp ss;` format `EU` + P1 + 2-digit steps: P1 `0`=MAIN dial, `8`=MULTI knob;
  steps `01`–`99`. Example: `EU005;` = turn main dial up 5 clicks.

#### EK — ENT key (set only)
- Set: `EK;` — presses the ENT key (used for direct frequency entry sequences).

#### FS — Fast step
- Set/Ans: `FS0;`/`FS1;` — VFO-A FAST key off/on. Read: `FS;`

### 3.2 Mode

#### MD — Operating mode
- Set: `MD0` + mode char + `;` (P1 fixed `0` = main RX). Read: `MD0;` → `MD0x;`

| Code | Mode (as reported) | Notes |
|------|--------------------|-------|
| 1 | LSB | SSB w/ SSB BFO; actual sideband follows menu 11-07 SSB BFO |
| 2 | USB | SSB w/ SSB BFO |
| 3 | CW | CW (BFO per menu 07-07 CW BFO); conventionally CW-USB |
| 4 | FM | |
| 5 | AM | |
| 6 | RTTY-LSB | BFO per menu 10-11 RTTY BFO |
| 7 | CW-R | CW reverse (opposite BFO side) |
| 8 | DATA-LSB | BFO per menu 08-12 DATA BFO |
| 9 | RTTY-USB | |
| A | (not used) | |
| B | FM-N | Narrow FM |
| C | DATA-USB | |
| D | AM-N | Narrow AM |

The manual notes the BFO side of SSB/CW/RTTY/DATA modes depends on the menu BFO
settings: `EX1107` (SSB), `EX0707` (CW), `EX0812` (DATA), `EX1011` (RTTY).
**Quirk [hamlib]:** the FT-891 cannot set VFO-B's mode directly; to change VFO-B mode,
set it on VFO-A then copy with `AB;` (or swap with `SV;`).

### 3.3 VFO and memory operations

#### AB / BA / SV — VFO copies and swap (set only)
- `AB;` copies VFO-A → VFO-B. `BA;` copies VFO-B → VFO-A. `SV;` swaps A ↔ B.

#### AM / VM — VFO-A → memory channel (set only)
- `AM;` writes VFO-A to the current memory channel. `VM;` emulates the [V/M] key
  (toggles VFO/memory; manual titles it "VFO-A TO MEMORY CHANNEL").

#### MA — Memory channel → VFO-A (set only)
- `MA;`

#### MC — Memory channel select
- Set: `MCnnn;` — `001`–`099` regular channels, `P1L`–`P9U` PMS pairs.
- Read: `MC;` → `MCnnn;`

#### CH — Memory channel up/down (set only)
- `CH0;` = channel up, `CH1;` = channel down.

#### MR — Memory channel read (read only)
- Read: `MRnnn;` with channel `001`–`099`, `P1L`–`P9U`, `501`–`510` (5 MHz, US/UK only),
  `EMG` (Alaska emergency).
- Answer (28+ chars): `MR` + P1 ch (3) + P2 freq (9, Hz) + `+/-` + P3 clar offset (4, Hz)
  + P4 clar on/off (1) + P5 `0` + P6 mode (1, memory-mode table: 1 LSB, 2 USB, 3 CW,
  4 FM, 5 AM, 6 RTTY-LSB, 7 CW-R, 8 DATA-LSB, 9 RTTY-USB, B FM-N, C DATA-USB, D AM-N)
  + P7 VFO/memory (1) + P8 CTCSS (0 off / 1 enc-dec / 2 enc) + P9 `00` + P10 shift
  (0 simplex / 1 plus / 2 minus) + `;`

#### MW — Memory channel write (set only)
- Set: `MW` + ch (3) + freq (9, Hz) + `+/-` + clar offset (4) + clar on/off (1) + `0`
  + mode (1) + `0` + CTCSS (1) + `00` + shift (1) + `;` — same field layout as MR answer.
  Channels `001`–`099` and `P1L`–`P9U` only.

#### MT — Memory write & tag
- Set: same layout as MW through P10, then P11 tag on/off (1) + P12 tag text
  (**12 characters, ASCII, always 12 — pad with spaces**) + `;`
- Read: `MTnnn;` → Answer echoes the full 41-char record including the tag.

#### QI / QR — Quick Memory Bank (set only)
- `QI;` stores current state to QMB; `QR;` recalls QMB.

#### SC — Scan
- Set: `SC0;` stop, `SC1;` scan up, `SC2;` scan down. Read: `SC;`

### 3.4 PTT / TX control

#### TX — TX set (CAT PTT)
- Set: `TX0;` = CAT PTT off (receive), `TX1;` = CAT PTT on (transmit).
- Read: `TX;` → Answer `TX0;` (RX), `TX1;` (transmitting due to CAT),
  `TX2;` (transmitting due to a non-CAT source — mic PTT, key, DAKY, etc.).
  `TX2` appears only in answers; do not send it.

#### MX — MOX
- Set: `MX0;`/`MX1;` MOX off/on. Read: `MX;` Functionally keys the transmitter like the
  front-panel MOX function.

#### TS — TXW (transmit-frequency watch)
- Set: `TS0;`/`TS1;`. While on, receiver monitors the TX (split) frequency.

#### BY — Busy (read only)
- Read: `BY;` → `BYp0;` — P1 `0`=RX not busy, `1`=busy (squelch open); P2 fixed `0`.

#### UL — PLL unlock (read only)
- Read: `UL;` → `UL0;` locked / `UL1;` unlocked.

#### RI — Radio information (read only)
- Read: `RIp;` with P1: `0`=Hi-SWR, `3`=REC, `4`=PLAY, `A`=TX LED, `B`=RX LED.
- Answer: `RIpx;` x `0`=off, `1`=on. Example: `RIA;` → `RIA1;` while transmitting.

#### PS — Power switch
- Set: `PS0;` off, `PS1;` on. Read: `PS;` → `PS1;`
- **Quirk (stated in manual):** to power the radio **on** via CAT, first send dummy
  data, then send `PS1;` after more than 1 s but less than 2 s. (The USB UART stays
  powered when the radio is off.)

### 3.5 Power output, tuner, meters

#### PC — Power control
- Set: `PCnnn;` — `005`–`100` watts, 3 digits zero-padded. Read: `PC;` → `PCnnn;`
  (Note: AM carrier power is separately capped at 40 W by menus 16-02/16-05.)

#### AC — Antenna tuner control
- Set: `AC00p;` — P1,P2 fixed `0`; P3: `0` tuner off, `1` tuner on, `2` **start tune
  cycle** (radio transmits a carrier while tuning; requires menu 16-15 TUNER SELECT
  configured for the attached tuner/ATAS).
- Read: `AC;` → `AC00p;` (P3 reflects tuner state; during tuning the state is `2`).

#### RM — Read meter (read only)
- Read: `RMp;` P1: `0` = whatever the front-panel meter shows, `1` = S-meter,
  `2` = front-panel TX meter (PO/COMP/ALC/SWR/ID), `3` = COMP, `4` = ALC, `5` = PO,
  `6` = SWR, `7` = ID.
- Answer: `RMpnnn;` — 3-digit raw value `000`–`255`. Scaling to real units is not
  published; calibrate empirically (hamlib uses lookup tables). **[COMMUNITY]**

#### SM — S-meter (read only)
- Read: `SM0;` → `SM0nnn;` raw `000`–`255`. (≈ S9 around 120 by community calibration
  **[UNVERIFIED]**.)

#### MS — Meter switch
- Set: `MSp;` selects front-panel TX meter: `0` COMP, `1` ALC, `2` PO, `3` SWR, `4` ID.

### 3.6 Receiver front end and gain

#### AG — AF gain
- Set: `AG0nnn;` (P1 fixed `0`, level `000`–`255`). Read: `AG0;` → `AG0nnn;`

#### RG — RF gain
- Set: `RG0nnn;` — level `000`–`030` (3 digits; only 0–30 valid). Read: `RG0;`

#### SQ — Squelch level
- Set: `SQ0nnn;` — `000`–`100`. Read: `SQ0;`

#### RA — RF attenuator
- Set: `RA00;` off / `RA01;` on. Read: `RA0;` → `RA0p;`

#### PA — Pre-amp (IPO)
- Set: `PA00;` = IPO (preamp bypass), `PA01;` = AMP (preamp on). Read: `PA0;`

#### GT — AGC
- Set: `GT0p;` P2: `0` off, `1` fast, `2` mid, `3` slow, `4` auto.
- Read: `GT0;` → Answer `GT0p;` where P3 (answer): `0` off, `1` fast, `2` mid, `3` slow,
  `4` auto-fast, `5` auto-mid, `6` auto-slow. Note the **set and answer encodings differ**
  for auto: you set `4` (auto) but read back 4/5/6 telling you which speed auto chose.

### 3.7 Clarifier (RIT)

The FT-891 has one clarifier; whether it applies to RX, TX, or both is menu
**05-18 CLAR SELECT** (`EX0518`: 0 RX / 1 TX / 2 TRX). There is no `XT` command.

#### CF — Clarifier on/off
- Set: `CF0p0;` — P2 `0` off / `1` on (P1, P3 fixed `0`). Read: `CF0;` → `CF0p0;`

#### RD / RU — Clarifier down / up (set only)
- Set: `RDnnnn;` / `RUnnnn;` — offset the clarifier by `0000`–`9999` Hz.
  These are **relative nudges** in the stated direction; there is no absolute
  clarifier-set command. Read the current offset and direction from `IF` (P3).

#### RC — Clarifier clear (set only)
- Set: `RC;` — zeroes the clarifier offset.

### 3.8 Split

#### ST — Split (the FT-891's split command; there is no FT/FR)
- Set: `ST0;` off, `ST1;` on (VFO-A = RX, VFO-B = TX), `ST2;` on + shift TX 5 kHz up.
- Read: `ST;` → `STp;`

#### QS — Quick split (set only)
- Set: `QS;` — engages quick split using the offset in menu 05-13 QUICK SPL FREQ.

#### OS — Repeater offset direction (FM only)
- Set: `OS0p;` — `0` simplex, `1` plus, `2` minus. Read: `OS0;`
  Offset amounts come from menus 09-04/09-05. Only works in FM modes.

### 3.9 DSP: width, narrow, shift, notch, contour, NB, NR

#### SH — Width (DSP IF bandwidth)
- Set: `SH0pnn;` — P2: `0` off / `1` on; P3 = 2-digit width code (table below).
- Read: `SH0;` → `SH0pnn;`

| P3 | SSB (NAR) | SSB (wide) | CW (NAR) | CW (wide) | RTTY/PSK (NAR) | RTTY/PSK (wide) |
|----|-----------|------------|----------|-----------|----------------|-----------------|
| 00 (default) | 1500 | 2400 | 500 | 2400 | 300 | 500 |
| 01 | 200 | – | 50 | – | 50 | – |
| 02 | 400 | – | 100 | – | 100 | – |
| 03 | 600 | – | 150 | – | 150 | – |
| 04 | 850 | – | 200 | – | 200 | – |
| 05 | 1100 | – | 250 | – | 250 | – |
| 06 | 1350 | – | 300 | – | 300 | – |
| 07 | 1500 | – | 350 | – | 350 | – |
| 08 | 1650 | – | 400 | – | 400 | – |
| 09 | 1800 | 1800 | 450 | – | 450 | – |
| 10 | – | 1950 | 500 | 500 | 500 | 500 |
| 11 | – | 2100 | – | 800 | – | 800 |
| 12 | – | 2200 | – | 1200 | – | 1200 |
| 13 | – | 2300 | – | 1400 | – | 1400 |
| 14 | – | 2400 | – | 1700 | – | 1700 |
| 15 | – | 2500 | – | 2000 | – | 2000 |
| 16 | – | 2600 | – | 2400 | – | 2400 |
| 17 | – | 2700 | – | 3000 | – | 3000 |
| 18 | – | 2800 | – | – | – | – |
| 19 | – | 2900 | – | – | – | – |
| 20 | – | 3000 | – | – | – | – |
| 21 | – | 3200 | – | – | – | – |

(All values Hz. "NAR" column applies when NA narrow is on. AM/FM widths are fixed
by NA only.)

#### NA — Narrow
- Set: `NA0p;` — `0` off / `1` on. Read: `NA0;`

#### IS — IF shift
- Set: `IS0p±nnnn;` — P2 `0` off / `1` on, then sign and 4-digit shift,
  `0000`–`1200` Hz in 20 Hz steps. Example: `IS01+1000;`. Read: `IS0;`
  (Manual's own example stresses the sign and 4-digit field are mandatory.)

#### BP — Manual notch
- Set: `BP00nnn;` — on/off: P2=`0`, P3 `000` off / `001` on.
  `BP01nnn;` — level: P2=`1`, P3 `001`–`320` = notch frequency × 10 Hz (10–3200 Hz).
- Read: `BP00;` or `BP01;` → `BP0pnnn;`

#### BC — Auto notch (DNF)
- Set: `BC00;` off / `BC01;` on. Read: `BC0;`

#### CO — Contour / APF
- Set: `CO0pnnnn;` — P2 selects the function, P3 is 4 digits:
  - P2=`0` contour on/off: P3 `0000` off, `0001` on
  - P2=`1` contour frequency: P3 `0010`–`3200` (Hz)
  - P2=`2` APF on/off: P3 `0000` off, `0001` on
  - P2=`3` APF frequency: P3 `0000`–`0050` encoding −250…+250 Hz (5 Hz? steps —
    encoding: value×10 − 250 Hz **[UNVERIFIED]**; manual states only "0000 - 0050
    (APF Frequency: -250 - 250 Hz)")
- Read: `CO0p;` → `CO0pnnnn;`

#### NB — Noise blanker on/off
- Set: `NB00;` off / `NB01;` on. Read: `NB0;`

#### NL — Noise blanker level
- Set: `NL0nnn;` — `000`–`010`. Read: `NL0;`
  (NB width/rejection are menus 05-01/05-02.)

#### NR — Noise reduction (DNR) on/off
- Set: `NR00;` off / `NR01;` on. Read: `NR0;`

#### RL — Noise reduction level
- Set: `RL0nn;` — `01`–`15`. Read: `RL0;` → `RL0nn;`

### 3.10 CW and keyer

#### KY — CW keying = **memory playback only** (set only)
- Set: `KYp;` — P1: `1`–`5` play keyer memory 1–5; `6`–`9`,`A` play message keyer 1–5.
- **Quirk:** unlike the FT-991/FT-DX radios, the FT-891 `KY` command **cannot send
  arbitrary text**. Load text into a keyer memory with `KM`, then trigger it with `KY`.

#### KM — Keyer memory text
- Set: `KMp` + up to 50 message characters + `;` — P1 channel `1`–`5`.
- Read: `KMp;` → `KMp<text>;`
  (The corresponding CW MEMORY menu item 04-07…04-11 must be set to TEXT for text
  playback. **[COMMUNITY]**)

#### KS — Key speed
- Set: `KSnnn;` — `004`–`060` WPM, 3 digits. Read: `KS;`

#### KP — Key pitch
- Set: `KPnn;` — `00`–`75` encoding 300–1050 Hz in 10 Hz steps (pitch = 300 + 10·n).
  Read: `KP;`

#### KR — Keyer on/off
- Set: `KR0;`/`KR1;`. Read: `KR;`

#### BI — Break-in on/off
- Set: `BI0;`/`BI1;`. Read: `BI;`

#### SD — Semi break-in (CW) delay
- Set: `SDnnnn;` — `0030`–`3000` ms, 4 digits. Read: `SD;`

#### CS — CW spot
- Set: `CS0;`/`CS1;`. Read: `CS;`

#### ZI — Zero in (set only)
- Set: `ZI;` — triggers the CW auto-zero-in function.

### 3.11 Voice / DVS

#### PB — DVS playback
- Set: `PB0p;` — `0` stop, `1`–`5` play voice memory channel. Read: `PB0;`

#### LM — DVS record
- Set: `LM0p;` — `0` stop recording, `1`–`5` start/stop recording channel n.
  Read: `LM0;`

### 3.12 VOX, monitor, speech processor, mic

#### VX — VOX on/off
- Set: `VX0;`/`VX1;`. Read: `VX;`

#### VG — VOX gain
- Set: `VGnnn;` — `000`–`100`. Read: `VG;`

#### VD — VOX delay
- Set: `VDnnnn;` — `0030`–`3000` ms (10 ms multiples), 4 digits. Read: `VD;`

#### MG — Mic gain
- Set: `MGnnn;` — `000`–`100`. Read: `MG;`

#### ML — Monitor level
- Set: `ML0nnn;` — P1=`0`: P2 `000` off / `001` on. `ML1nnn;` — P1=`1`: level `000`–`100`.
- Read: `ML0;` or `ML1;` → `MLpnnn;`

#### PR — Speech processor / parametric EQ on/off
- Set: `PR0p;` — speech processor off/on; `PR1p;` — parametric mic EQ off/on
  (P2 `0` off, `1` on). Read: `PR0;` / `PR1;`

#### PL — Speech processor level
- Set: `PLnnn;` — `000`–`100`. Read: `PL;`

### 3.13 CTCSS / DCS (FM)

#### CT — Tone mode
- Set: `CT0p;` — `0` off, `1` CTCSS ENC/DEC, `2` CTCSS ENC, `3` DCS on. Read: `CT0;`

#### CN — Tone / DCS code number
- Set: `CN0pnnn;` — P2 `0`=CTCSS, `1`=DCS; P3 3-digit index:
  CTCSS `000`–`049` (see table), DCS `000`–`103`.
- Read: `CN0p;` → `CN0pnnn;`

CTCSS tone table (index → Hz): 000 67.0, 001 69.3, 002 71.9, 003 74.4, 004 77.0,
005 79.7, 006 82.5, 007 85.4, 008 88.5, 009 91.5, 010 94.8, 011 97.4, 012 100.0,
013 103.5, 014 107.2, 015 110.9, 016 114.8, 017 118.8, 018 123.0, 019 127.3,
020 131.8, 021 136.5, 022 141.3, 023 146.2, 024 151.4, 025 156.7, 026 159.8,
027 162.2, 028 165.5, 029 167.9, 030 171.3, 031 173.8, 032 177.3, 033 179.9,
034 183.5, 035 186.2, 036 189.9, 037 192.8, 038 196.6, 039 199.5, 040 203.5,
041 206.5, 042 210.7, 043 218.1, 044 225.7, 045 229.1, 046 233.6, 047 241.8,
048 250.3, 049 254.1.

DCS code table (index → code): 000 023, 001 025, 002 026, 003 031, 004 032, 005 036,
006 043, 007 047, 008 051, 009 053, 010 054, 011 065, 012 071, 013 072, 014 073,
015 074, 016 114, 017 115, 018 116, 019 122, 020 125, 021 131, 022 132, 023 134,
024 143, 025 145, 026 152, 027 155, 028 156, 029 162, 030 165, 031 172, 032 174,
033 205, 034 212, 035 223, 036 225, 037 226, 038 243, 039 244, 040 245, 041 246,
042 251, 043 252, 044 255, 045 261, 046 263, 047 265, 048 266, 049 271, 050 274,
051 306, 052 311, 053 315, 054 325, 055 331, 056 332, 057 343, 058 346, 059 351,
060 356, 061 364, 062 365, 063 371, 064 411, 065 412, 066 413, 067 423, 068 431,
069 432, 070 445, 071 446, 072 452, 073 454, 074 455, 075 462, 076 464, 077 465,
078 466, 079 503, 080 506, 081 516, 082 523, 083 526, 084 532, 085 546, 086 565,
087 606, 088 612, 089 624, 090 627, 091 631, 092 632, 093 654, 094 662, 095 664,
096 703, 097 712, 098 723, 099 731, 100 732, 101 734, 102 743, 103 754.

### 3.14 Status / information

#### IF — Information (read only) — the main polling command
- Read: `IF;` → Answer, 28 characters:

| Chars | Field | Format |
|-------|-------|--------|
| 1–2 | `IF` | literal |
| 3–5 | P1 memory channel | `001`–`099`, `P1L`–`P9U`, `501`–`510` (5 MHz US/UK), `EMG` |
| 6–14 | P2 VFO-A frequency | 9 digits, Hz |
| 15 | P3 sign | `+`/`-` clarifier direction |
| 16–19 | P3 clarifier offset | `0000`–`9999` Hz |
| 20 | P4 clarifier | `0` off, `1` on |
| 21 | P5 | fixed `0` |
| 22 | P6 mode | same codes as MD (1…D) |
| 23 | P7 | `0` VFO, `1` memory, `2` memory tune, `5` PMS |
| 24 | P8 CTCSS | `0` off, `1` ENC/DEC, `2` ENC |
| 25–26 | P9 | fixed `00` |
| 27 | P10 shift | `0` simplex, `1` plus, `2` minus |
| 28 | `;` | terminator |

#### OI — Opposite band information (read only)
- Read: `OI;` → same layout as IF but for **VFO-B**; P7 additionally allows
  `3` QMB, `4` QMB-MT, `6` HOME.

#### ID — Identification (read only)
- Read: `ID;` → `ID0650;` — `0650` identifies the FT-891.

#### RS — Radio status (read only)
- Read: `RS;` → `RS0;` normal, `RS1;` front-panel menu mode active.

#### AI — Auto information
- Set: `AI0;`/`AI1;`. Read: `AI;` → `AIp;`. Reset to 0 at power-off.

### 3.15 Miscellaneous

#### DA — Dimmer
- Set: `DA` + P1 contrast (2, `01`–`15`) + P2 backlight (2, `01`–`15`)
  + P3 LCD dimmer (2, `00`–`15`) + P4 TX/BUSY dimmer (2, `00`–`15`) + `;`
- Read: `DA;` → full 8-digit answer.

#### LK — Lock
- Set: `LK0;`/`LK1;` — main dial lock off/on. Read: `LK;`

#### EX — Menu access
- Set: `EX` + 4-digit menu number + value + `;`
- Read: `EX` + 4-digit menu number + `;` → `EX<nnnn><value>;`
- Menu numbers `0101`–`1803`; menu `NN-MM` on the front panel maps to P1 = `NNMM`
  (both parts zero-padded to 2 digits). Value formats/digit counts are per-item —
  see `ft891-menus.md` for the complete table.

---

## 4. Known quirks and implementation notes

1. **Fixed-width parameters.** Every numeric field must be sent with its exact digit
   count, zero-padded, with explicit `+`/`-` where the spec shows a sign position.
   `FA14250000;` (8 digits) is invalid; `FA014250000;` is required.
2. **Frequency is 9 digits of Hz** everywhere (FA/FB/IF/OI/MR/MW/MT).
3. **AI mode resets at power-off** — re-enable `AI1;` after every radio power cycle.
4. **PS power-on timing** — see PS above (dummy bytes + 1–2 s wait).
5. **No FR/FT** — split is `ST`; TX watch is `TS`; there is no independent
   RX-VFO/TX-VFO selection.
6. **VFO-B mode cannot be set directly** (hamlib): set mode on A, then `AB;` or `SV;`.
7. **KY cannot send free text** — memory playback only (`KM` to load, `KY` to send).
8. **GT answer encoding differs from set encoding** (auto → auto-fast/mid/slow).
9. **RM/SM return raw 0–255**; no published engineering-unit scaling.
10. **Clarifier is nudge-only** (RD/RU relative, RC clear); read absolute offset from IF.
11. **Menu mode**: while the operator is in the front-panel menu (`RS1;`), treat the
    radio as busy; Set-command behavior in menu mode is undocumented. **[UNVERIFIED]**
12. **BS band select** has no code `02` and no 5 MHz entry.
13. **AM power** is limited to 40 W (menus 16-02/16-05) even though `PC` accepts up
    to 100.
14. **CAT RTS (menu 05-08)** defaults to ENABLE; a host that never asserts RTS can
    appear "deaf" until this is disabled. **[COMMUNITY]**
15. **Responses have no CR/LF** — parse on `;` only. Multiple commands may be
    concatenated in one write (each terminated by `;`), but pace writes; the radio's
    CAT TOT (05-07) default is 10 ms.
16. **hamlib uses 27–28 char IF parsing and 8N2 framing** for this radio; if reads
    fail at 8N1 try 8N2. **[UNVERIFIED]**
