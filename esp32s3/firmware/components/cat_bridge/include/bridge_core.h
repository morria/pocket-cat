/*
 * bridge_core — the only place with business logic (docs/implementation.md §5).
 *
 * Platform-independent state machine wired to the USB and BLE links through
 * injected sinks/ops, so the identical code runs under ESP-IDF and inside the
 * host end-to-end simulation.
 *
 * Threading contract (matches §5.1):
 *   - bridge_on_usb_rx()        producer ctx (USB driver callback)   → ring only
 *   - bridge_on_ble_cat_write() producer ctx (NimBLE host task)      → ring only
 *   - bridge_on_ctrl_write()    producer ctx (NimBLE host task)      → ctrl queue only
 *   - bridge_on_*_connected/disconnected(): set atomic flags only
 *   - bridge_poll()             THE bridge task; everything else runs here
 */
#ifndef BRIDGE_CORE_H
#define BRIDGE_CORE_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "coalescer.h"
#include "ctrl_proto.h"
#include "ring_buf.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BRIDGE_FW_MAJOR 0
#define BRIDGE_FW_MINOR 1

/* Ring sizing per §5.3. */
#define BRIDGE_RB_USB_TO_BLE_CAP 2048u
#define BRIDGE_RB_BLE_TO_USB_CAP 1024u

#define BRIDGE_USB_TX_CHUNK 64u        /* per-poll USB write granularity     */
#define BRIDGE_MIN_MTU_PAYLOAD 20u     /* ATT_MTU 23 − 3                     */
#define BRIDGE_OVERFLOW_EVT_MIN_INTERVAL_MS 1000u /* §5.4 rate limit         */
#define BRIDGE_BLE_ABSENT_PURGE_MS 1000u /* keep filling ≤1 s then purge §5.5 */

/* EVT_OVERFLOW `which` values. */
#define BRIDGE_OVF_USB_TO_BLE 0u
#define BRIDGE_OVF_BLE_TO_USB 1u

/*
 * Sinks and ops the platform provides. Every function returns 0 on success,
 * non-zero on failure. ble_notify_* returning non-zero means backpressure:
 * the bridge retries the same bytes on a later poll (§5.1 — never a drop).
 */
typedef struct {
    int (*usb_tx)(void *ctx, const uint8_t *data, size_t len);
    int (*ble_notify_cat)(void *ctx, const uint8_t *data, size_t len);
    int (*ble_notify_ctrl)(void *ctx, const uint8_t *data, size_t len);
    int (*ble_notify_status)(void *ctx, const uint8_t *data, size_t len);
    int (*set_baud)(void *ctx, uint32_t baud);
    int (*set_line)(void *ctx, bool dtr, bool rts);
    int (*usb_reset)(void *ctx);
    uint32_t (*now_ms)(void *ctx);
    void *ctx;
} bridge_ops_t;

typedef struct {
    bridge_ops_t ops;

    /* Datapath rings (storage injected: static on target, arrays in tests). */
    ring_buf_t rb_usb_to_ble;
    ring_buf_t rb_ble_to_usb;
    coalescer_t coal;

    /* Control command queue: records of [len][frame...] written by the BLE
     * producer, drained by bridge_poll. */
    ring_buf_t ctrl_q;
    uint8_t ctrl_q_storage[256];

    /* Link state (producer-set, poll-consumed). */
    _Atomic bool ble_connected;
    _Atomic bool ble_cat_subscribed;
    _Atomic bool failsafe_fire; /* set on BLE disconnect when armed */

    /* Failsafe string — owned by bridge_poll after arm (§4.1). */
    uint8_t failsafe[CTRL_FAILSAFE_MAX];
    _Atomic uint8_t failsafe_len;

    /* USB link (poll-context once wired; producers only set the atomics). */
    _Atomic uint8_t usb_state; /* ctrl_usb_state_t */
    _Atomic uint8_t radio_id;  /* ctrl_radio_id_t  */
    uint32_t baud;
    uint8_t reset_reason;
    uint32_t min_free_heap;

    /* BLE payload size = ATT_MTU − 3, clamped to COAL_BUF_SIZE. */
    _Atomic uint16_t mtu_payload;

    /* Poll-local bookkeeping. */
    uint32_t last_ovf_evt_ms;
    uint32_t reported_drops_u2b;
    uint32_t reported_drops_b2u;
    uint32_t ble_absent_since_ms;
    bool ble_absent_purged;
    bool status_dirty;
    bool evt_usb_pending;
    uint8_t last_status[CTRL_STATUS_SIZE];
} bridge_t;

void bridge_init(bridge_t *b, const bridge_ops_t *ops,
                 uint8_t *usb2ble_storage, size_t usb2ble_cap,
                 uint8_t *ble2usb_storage, size_t ble2usb_cap);

/* --- Producer-context entry points (bounded work only) ------------------- */
void bridge_on_usb_rx(bridge_t *b, const uint8_t *data, size_t len);
void bridge_on_ble_cat_write(bridge_t *b, const uint8_t *data, size_t len);
void bridge_on_ctrl_write(bridge_t *b, const uint8_t *data, size_t len);
void bridge_on_ble_connected(bridge_t *b);
void bridge_on_ble_disconnected(bridge_t *b);
void bridge_on_ble_cat_subscribed(bridge_t *b, bool subscribed);
void bridge_set_mtu(bridge_t *b, uint16_t att_mtu);

/* --- USB lifecycle (called from the bridge/usb task context) -------------- */
void bridge_on_usb_connected(bridge_t *b, ctrl_radio_id_t radio,
                             uint32_t default_baud);
/* A device is attached but we could not open a CAT interface for it
 * (unknown descriptor, or a driver we don't implement). Reports the radio
 * id so the app can say "unsupported device" rather than "no radio", while
 * keeping usb_state out of ENUMERATED — nothing can be written. */
void bridge_on_usb_unsupported(bridge_t *b, ctrl_radio_id_t radio);
void bridge_on_usb_disconnected(bridge_t *b);
void bridge_on_usb_error(bridge_t *b);

/* --- The bridge task body -------------------------------------------------
 * Run one pump iteration. Returns true if any work was done (caller may
 * sleep briefly when idle). */
bool bridge_poll(bridge_t *b);

/* Snapshot for READ on the STATUS characteristic. Returns CTRL_STATUS_SIZE. */
int bridge_status_read(bridge_t *b, uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* BRIDGE_CORE_H */
