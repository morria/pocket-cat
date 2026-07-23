# NimBLE (ESP-IDF) — BLE Link Firmware Reference

How the `ble_link` component implements the GATT server from
`../implementation.md` §4. Targets the ESP-IDF **NimBLE** host (Apache Mynewt
port bundled with ESP-IDF).

> Sources: ESP-IDF NimBLE API docs (`docs.espressif.com`), `esp-idf`
> `examples/bluetooth/nimble/*` (esp-idf on GitHub is reachable; the rendered
> docs host is egress-blocked). Confirm API signatures against your ESP-IDF tag.

## Why NimBLE

Peripheral-only, smaller RAM/flash than Bluedroid, well-suited to a single-link
CAT bridge. Enable in sdkconfig:

```
CONFIG_BT_ENABLED=y
CONFIG_BT_NIMBLE_ENABLED=y
CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1
CONFIG_BT_NIMBLE_ROLE_PERIPHERAL=y
CONFIG_BT_NIMBLE_ROLE_CENTRAL=n
CONFIG_BT_NIMBLE_ROLE_OBSERVER=n
CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=247   # request a large MTU; iOS caps it
CONFIG_BT_NIMBLE_SECURITY_ENABLE=y       # bonding for release builds
```

## GATT table (matches implementation.md §4)

Generate a project base UUID (record it in `../protocol.md`). One primary
service, four characteristics:

| Char | Flags (NimBLE) | Role |
|---|---|---|
| `CAT_RX` | `WRITE \| WRITE_NO_RSP` | central→radio raw CAT |
| `CAT_TX` | `NOTIFY` | radio→central raw CAT |
| `CTRL` | `WRITE \| NOTIFY` | TLV control (§4.1) |
| `STATUS`| `READ \| NOTIFY` | packed status struct |

```c
static const struct ble_gatt_svc_def svcs[] = {
  { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &SVC_UUID.u,
    .characteristics = (struct ble_gatt_chr_def[]){
      { .uuid=&CAT_RX.u,  .access_cb=cat_rx_cb,
        .flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_NO_RSP },
      { .uuid=&CAT_TX.u,  .access_cb=cat_tx_cb,
        .flags=BLE_GATT_CHR_F_NOTIFY, .val_handle=&cat_tx_handle },
      { .uuid=&CTRL.u,    .access_cb=ctrl_cb,
        .flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_NOTIFY, .val_handle=&ctrl_handle },
      { .uuid=&STATUS.u,  .access_cb=status_cb,
        .flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_NOTIFY, .val_handle=&status_handle },
      { 0 } } },
  { 0 } };
```

## Datapath in — `CAT_RX` write callback

Copy the ATT payload straight into `rb_ble_to_usb` and return. **No processing**
in host-task context.

```c
static int cat_rx_cb(uint16_t ch, uint16_t attr, struct ble_gatt_access_ctxt *c, void *a){
    uint16_t n = OS_MBUF_PKTLEN(c->om);
    ble_hs_mbuf_to_flat(c->om, scratch, sizeof scratch, &n);
    ring_write_drop_newest(&rb_ble_to_usb, scratch, n);   // bounded
    return 0;
}
```

## Datapath out — `CAT_TX` notifications

The bridge task drains `rb_usb_to_ble` and notifies in `min(MTU-3, avail)`
chunks. Flush triggers: `;` seen, MTU-full, or 8 ms idle (§5.3).

```c
struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, len);
int rc = ble_gatts_notify_custom(conn_handle, cat_tx_handle, om);
// rc == BLE_HS_ENOMEM  → controller out of buffers.
//   DO NOT drop: leave bytes in the ring, retry next tick (backpressure, §5.1).
```

Effective payload = **negotiated ATT_MTU − 3**. Get it with
`ble_att_mtu(conn_handle)`; never assume > 20 until MTU exchange completes
(`BLE_GAP_EVENT_MTU`).

## Advertising & connection

- Put the **service UUID in the advertising payload** (not just the scan
  response) so iOS background scanning / state restoration can rediscover the
  bridge. Device name in the scan response.
- On connect: `ble_gap_adv_stop()` implicitly (single link) — **resume
  advertising on `BLE_GAP_EVENT_DISCONNECT`**; that resume *is* the
  "single-central" enforcement (§4).
- Request a faster connection interval for low CAT latency
  (`ble_gap_update_params`, ~15–30 ms). iOS ultimately dictates the interval.

## Security / bonding (release default)

```
CONFIG_BT_NIMBLE_SECURITY_ENABLE=y
CONFIG_BT_NIMBLE_SM_LEGACY=y
CONFIG_BT_NIMBLE_SM_SC=y            # LE Secure Connections
CONFIG_BT_NIMBLE_MAX_BONDS=1
```

- `ble_hs_cfg.sm_bonding=1; sm_sc=1; sm_mitm=0` (Just Works default; passkey is
  an open question, §9). Store keys in NVS
  (`CONFIG_BT_NIMBLE_NVS_PERSIST=y`).
- Require encryption before honoring `CAT_RX`/`CTRL` writes in release builds —
  an unauthenticated peer must not be able to key a transmitter (§4). The
  debug-open build flag disables this and triggers the LED "insecure" pattern
  (§5.6).

## Events to handle

`BLE_GAP_EVENT_CONNECT`, `DISCONNECT`, `MTU`, `SUBSCRIBE` (track CCCD for
`CAT_TX`/`CTRL`/`STATUS`), `ENC_CHANGE`, `REPEAT_PAIRING`,
`CONN_UPDATE`. On disconnect: fire the USB `SET_FAILSAFE` path, purge
`rb_ble_to_usb`, resume advertising.

## Reference examples to mirror

- `esp-idf` → `examples/bluetooth/nimble/bleprph` (peripheral + GATT + bonding).
- `examples/bluetooth/nimble/bleprph_wr_throughput` (notify throughput/MTU).
