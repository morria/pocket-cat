# Yaesu FTX-1 — CAT Reference

The FTX-1 (SDR field/base transceiver) uses the same modern Yaesu ASCII CAT
dialect as the FT-891 / FT-710 / FT-991A. This doc captures **only the deltas**
that matter for the bridge; for the command grammar and mode codes, start from
[`yaesu-cat-ft891.md`](yaesu-cat-ft891.md).

> Source of record: *FTX-1 Series CAT Operation Reference Manual* (Yaesu),
> supported on **MAIN firmware ≥ 1.08**. Values here are from the manual's
> published summary and the FT-710-family lineage; **confirm on real hardware
> at M7 bring-up** (`../implementation.md` §9 open question 1).

## USB / serial layer

- The FTX-1 has a **built-in USB-to-Dual-UART bridge** and exposes, per Yaesu's
  own text, two ports in Windows:
  - *Silicon Labs Dual CP210x USB to UART Bridge: **Enhanced** COM Port* → **CAT**
  - *Silicon Labs Dual CP210x USB to UART Bridge: **Standard** COM Port* →
    secondary (TX/PTT/flow/keying), same split as the FT-891's CP2105.
- So the FTX-1 is a **CP210x-family dual-UART device** on VID `0x10C4`. The
  exact **PID and whether it is a composite device that also exposes a USB audio
  interface (like the FT-710) is unconfirmed** — the radio-detect table must
  match per-interface and pick the serial/Enhanced interface (see
  `../implementation.md` §5.2). Capture the real descriptor with `lsusb -v` at
  bring-up and record it here.
- **Framing:** 8-N-1. **Baud:** selectable in the radio menu; the FT-710/FTX-1
  family supports up to `38400` (some firmwares expose higher). Default to a
  safe value and let the app negotiate, same policy as the FT-891.

## CAT grammar

Identical to the FT-891:

- 2-letter opcode, ASCII params, `;` (0x3B) terminator.
- Set / Read / Answer / Auto-send semantics; `?;` on invalid.
- `MD` mode-code table is the Yaesu newcat table (see FT-891 doc). The FTX-1 is
  a full-mode SDR, so expect the DATA/C4FM codes (`8`,`A`–`F`) to be live.
- `IF;`, `FA;`/`FB;`, `TX;`, `ID;`, `PS;`, `AI;`, meters, gains — as FT-891.

## Deltas to confirm at bring-up

Fill these in from the FTX-1 CAT Operation Reference Manual + a live rig:

- [ ] `ID;` response code for the FTX-1 (FT-891 is `0650`; FT-710 is `0761`).
      Needed as the baud-probe / model-detect token.
- [ ] Exact USB VID/**PID**, and whether a **USB audio (UAC) interface** is
      present alongside the two UARTs (composite descriptor dump).
- [ ] Which of the dual UARTs is Enhanced vs Standard at the USB **interface
      index** level (don't assume it matches the FT-891's CP2105 numbering).
- [ ] Any FTX-1-only commands (band-stacking, SDR scope/`SC`, dual-receive
      `DR`, GPS/`GP`, etc.) the app may want — not required for the bridge.
- [ ] Whether `CAT RTS`-equivalent menu forces RTS assertion for CAT.

Until confirmed, the FTX-1 falls through the bridge's **generic Yaesu / generic
CP210x** profile, which is functionally sufficient: the app speaks the same CAT,
and only driver/interface selection and default baud depend on the descriptor.
