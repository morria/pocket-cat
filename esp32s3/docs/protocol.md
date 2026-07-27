# CAT Bridge BLE Protocol — v0.1 (normative)

The interface contract between the ESP32-S3 bridge firmware and any central
(the iOS app, `test/tools/ble_client.py`). Firmware and clients MUST be coded
against this document; changes land in the same PR as the firmware change
(docs/implementation.md §6).

Implementations: firmware `components/ctrl_proto` + `components/ble_link`;
Python reference `test/tools/catproto.py`.

## 1. GATT layout

Base UUID: `8f1dXXXX-52a4-4e1e-b34b-9d40b71d6e01`.

| XXXX | Name | Properties | Direction | Payload |
|------|------|-----------|-----------|---------|
| `0001` | Service | — | — | primary service |
| `0002` | `CAT_RX` | Write, Write-No-Response | central → radio | raw CAT bytes, no framing |
| `0003` | `CAT_TX` | Notify | radio → central | raw CAT bytes, chunked ≤ ATT_MTU−3 |
| `0004` | `CTRL` | Write, Notify | both | TLV frames (§2) |
| `0005` | `STATUS` | Read, Notify | device → central | packed status (§3) |
| `0006` | `SPECTRUM` | Notify | device → central | fragmented spectrum frames (§6); absent on builds without the DSP path |

- Advertising: the service UUID is in the ADV payload (iOS background
  rediscovery); the device name `CATBridge-XXXX` is in the scan response.
- Single central: advertising stops while connected, resumes on disconnect.
- Security: release builds require an encrypted (bonded, LE Secure
  Connections Just Works) link before `CAT_RX`/`CTRL` writes are accepted;
  unencrypted writes get ATT "insufficient authentication". Debug builds
  (`BRIDGE_BLE_REQUIRE_BONDING=n`) accept writes on open links.
- The CAT stream is 100 % transparent. The bridge's only protocol awareness
  is using a trailing `;` as a notification flush hint.

## 2. CTRL TLV frames

```
[opcode:1][len:1][payload:len]      all multi-byte integers little-endian
```

### Central → peripheral commands

| Op | Name | Payload | Errors |
|----|------|---------|--------|
| `0x01` | `SET_BAUD` | u32 baud | `BAD_LEN`, `BAD_ARG` (outside 300–3 000 000), `NO_USB`, `BUSY` |
| `0x02` | `GET_STATUS` | — | `BAD_LEN` |
| `0x03` | `USB_RESET` | — | `BAD_LEN`, `NO_USB` (nothing attached), `BUSY` |
| `0x04` | `SET_LINE` | u8 bitmap: bit0 DTR, bit1 RTS | `BAD_LEN`, `NO_USB`, `BUSY` |
| `0x05` | `PURGE` | u8 mask: bit0 usb→ble, bit1 ble→usb | `BAD_LEN`, `BAD_ARG` (zero or unknown bits) |
| `0x06` | `SET_FAILSAFE` | 0–32 raw bytes (empty = disarm) | `BAD_LEN` (> 32) |
| `0x07` | `SET_SPECTRUM` | `[enable:u8][bins:u16][fps:u8]` | `BAD_LEN`, `BAD_ARG` (bins ∉ {64,128,256,512}, fps ∉ 1–30, or unachievable at the live MTU), `UNSUPPORTED` (no DSP path), `NO_USB` (reserved for the real I/Q source) |

Reply rule: **every command yields exactly one reply frame.**

- `GET_STATUS` → `[0x02][22][status]` (the answer IS the ack).
- Everything else → `ACK` or `NAK`.
- A syntactically corrupt frame → `NAK` with the claimed opcode and `BAD_LEN`.

### Peripheral → central frames

| Op | Name | Payload |
|----|------|---------|
| `0x80` | `ACK` | `[orig_opcode, 0x00]` |
| `0x81` | `NAK` | `[orig_opcode, err]` |
| `0x82` | `EVT_USB` | `[usb_state, radio_id]` — emitted on attach/detach/error |
| `0x83` | `EVT_OVERFLOW` | `[which, dropped:u32]` — `which`: 0 usb→ble, 1 ble→usb; rate-limited to 1/s; `dropped` is the delta since the last event |

Error codes: `0` OK, `1` BAD_LEN, `2` BAD_ARG, `3` NO_USB, `4` UNSUPPORTED,
`5` BUSY, `6` UNKNOWN_OP.

### Failsafe semantics (stuck-PTT protection)

`SET_FAILSAFE` stores a byte string the bridge writes to the radio **once**,
on BLE disconnect or supervision timeout, *before* purging the ble→usb path.
It is cleared after firing, on USB detach, and by an empty `SET_FAILSAFE`.
The app MUST arm it with the dialect's unkey string (`TX0;` Yaesu, `RX;`
QMX/Kenwood) before keying PTT, and SHOULD disarm after unkey.

## 3. STATUS payload (22 bytes, little-endian)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | format version = `1` |
| 1 | 1 | usb_state: 0 waiting, 1 enumerated, 2 error |
| 2 | 1 | radio_id: 0 none, 1 FT-891, 2 generic CP210x, 3 QMX/CDC, 4 FTDI, 5 unsupported |
| 3 | 4 | current baud |
| 7 | 4 | lifetime dropped bytes usb→ble |
| 11 | 4 | lifetime dropped bytes ble→usb |
| 15 | 1 | fw major |
| 16 | 1 | fw minor |
| 17 | 1 | reset reason (esp_reset_reason enum; 0 unknown) |
| 18 | 4 | minimum free heap (bytes) |

Notified on change (link state, baud, new drops); readable at any time.

## 4. Data-path guarantees

- **Ordering**: bytes are delivered in order in both directions.
- **Loss**: the only loss points are the two rings (drop-newest, counted,
  reported via `EVT_OVERFLOW`) and USB write failure during a fault. BLE
  notify backpressure never drops (§5.1) — bytes are retried.
- **Chunking**: `CAT_TX` notifications are at most ATT_MTU−3 bytes; a CAT
  response may span several notifications and multiple responses may share
  one notification. Flush occurs on trailing `;`, full chunk, or 8 ms idle.
- **Radio absent**: `CAT_RX` writes while no radio is enumerated are
  discarded (counted as ble→usb behavior: purged, not forwarded).
- **Central absent**: radio bytes are retained for ≤ 1 s after disconnect,
  then purged; a reconnecting central never receives stale data.

## 5. Client obligations (informative)

See docs/implementation.md §6: dialect selection by `radio_id`, `ID;` baud
probing, poll cadence, `EVT_OVERFLOW` recovery (drop partial buffer, re-poll),
Write-No-Response with `canSendWriteWithoutResponse` throttling on iOS, and
failsafe arming around PTT.

## 6. SPECTRUM frames (panadapter; docs/qmx-panadapter.md is the design)

Little-endian. Fragment 0 carries the header; continuations only place
their bins:

```
frag 0 : [seq:u8][frag:u8=0][nfrags:u8][flags:u8][first_bin:u16]
         [bins_total:u16][sample_rate_hz:u32][bin bytes…]   header 12 B
frag n : [seq:u8][frag:u8][nfrags:u8][first_bin:u16][bin bytes…]
                                                            header  5 B
```

- `flags` = 0 in v1; centrals drop frames with unknown flags.
- Bins are dBFS at 0.5 dB/LSB (`0` = full scale). Bin 0 is the lowest
  frequency; bin `bins_total/2` is DC (the tuned frequency). Span is
  `sample_rate_hz`. Frames carry **no frequency** — axis labelling is the
  central's job from the VFO it already tracks.
- `seq` is assigned at frame *generation* and wraps at 256; a gap in
  received sequence numbers is the drop report — there is no CTRL event.
- Frames are sent atomically (a failed fragment abandons the rest) and are
  **never retried or queued behind CAT**: the stream inverts §4's
  no-drop guarantee by design, so a spectrum backlog can never delay CAT
  or trip the failsafe. `SET_SPECTRUM enable=1` while streaming
  reconfigures in place. Streaming auto-stops on BLE disconnect and USB
  detach; a reconnecting central always starts quiet.
- Golden fragment vectors live in `test/vectors/ctrlproto.json`
  (`spectrum_frames`), byte-shared with the Swift tests.
