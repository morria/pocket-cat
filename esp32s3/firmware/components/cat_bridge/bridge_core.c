#include "bridge_core.h"

#include <string.h>

#include "spectrum.h"

/* The QMX's I/Q sample rate; carried in every spectrum frame so the app
 * never hard-codes it (docs/qmx-panadapter.md §1.1). The synthetic source
 * pretends the same rate the real UAC path (plan M4) will deliver. */
#define BRIDGE_SPEC_SAMPLE_RATE_HZ 48000u

/* ---------------------------------------------------------------------- */
/* Init                                                                    */
/* ---------------------------------------------------------------------- */

void bridge_init(bridge_t *b, const bridge_ops_t *ops,
                 uint8_t *usb2ble_storage, size_t usb2ble_cap,
                 uint8_t *ble2usb_storage, size_t ble2usb_cap)
{
    memset(b, 0, sizeof *b);
    b->ops = *ops;
    ring_init(&b->rb_usb_to_ble, usb2ble_storage, usb2ble_cap);
    ring_init(&b->rb_ble_to_usb, ble2usb_storage, ble2usb_cap);
    ring_init(&b->ctrl_q, b->ctrl_q_storage, sizeof b->ctrl_q_storage);
    coal_init(&b->coal, COAL_DEFAULT_IDLE_MS);
    atomic_store(&b->usb_state, (uint8_t)CTRL_USB_WAITING);
    atomic_store(&b->radio_id, (uint8_t)CTRL_RADIO_NONE);
    atomic_store(&b->mtu_payload, BRIDGE_MIN_MTU_PAYLOAD);
    b->baud = 0;
    b->status_dirty = true;
}

/* ---------------------------------------------------------------------- */
/* Producer-context entry points                                           */
/* ---------------------------------------------------------------------- */

void bridge_on_usb_rx(bridge_t *b, const uint8_t *data, size_t len)
{
    ring_write(&b->rb_usb_to_ble, data, len);
}

void bridge_on_ble_cat_write(bridge_t *b, const uint8_t *data, size_t len)
{
    ring_write(&b->rb_ble_to_usb, data, len);
}

void bridge_on_ctrl_write(bridge_t *b, const uint8_t *data, size_t len)
{
    /* Queue as one [len][frame] record; oversize or ring-full frames are
     * dropped whole — the central notices the missing ACK and retries. */
    if (len == 0 || len > CTRL_MAX_FRAME) {
        return;
    }
    if (ring_free(&b->ctrl_q) < len + 1) {
        return;
    }
    uint8_t reclen = (uint8_t)len;
    ring_write(&b->ctrl_q, &reclen, 1);
    ring_write(&b->ctrl_q, data, len);
}

void bridge_on_ble_connected(bridge_t *b)
{
    atomic_store(&b->ble_connected, true);
}

void bridge_on_ble_disconnected(bridge_t *b)
{
    atomic_store(&b->ble_connected, false);
    atomic_store(&b->ble_cat_subscribed, false);
    /* Spectrum subscription dies with the link, and the generation bump
     * guarantees pump_spectrum kills the poll-owned enable even if the
     * central reconnects before the next poll — a reconnecting central
     * always starts quiet (docs/qmx-panadapter.md §3.2). */
    atomic_store(&b->ble_spectrum_subscribed, false);
    atomic_fetch_add(&b->ble_conn_gen, 1u);
    if (atomic_load(&b->failsafe_len) > 0) {
        atomic_store(&b->failsafe_fire, true); /* §5.5: emit before purge */
    }
}

void bridge_on_ble_cat_subscribed(bridge_t *b, bool subscribed)
{
    atomic_store(&b->ble_cat_subscribed, subscribed);
}

void bridge_on_spectrum_subscribed(bridge_t *b, bool subscribed)
{
    atomic_store(&b->ble_spectrum_subscribed, subscribed);
}

void bridge_set_mtu(bridge_t *b, uint16_t att_mtu)
{
    uint16_t payload = att_mtu > 3 ? (uint16_t)(att_mtu - 3)
                                   : BRIDGE_MIN_MTU_PAYLOAD;
    if (payload > COAL_BUF_SIZE) {
        payload = COAL_BUF_SIZE;
    }
    if (payload < BRIDGE_MIN_MTU_PAYLOAD) {
        payload = BRIDGE_MIN_MTU_PAYLOAD;
    }
    atomic_store(&b->mtu_payload, payload);
}

/* ---------------------------------------------------------------------- */
/* USB lifecycle (bridge/usb task context)                                 */
/* ---------------------------------------------------------------------- */

static void mark_usb_change(bridge_t *b)
{
    b->status_dirty = true;
    b->evt_usb_pending = true;
}

void bridge_on_usb_connected(bridge_t *b, ctrl_radio_id_t radio,
                             uint32_t default_baud)
{
    atomic_store(&b->usb_state, (uint8_t)CTRL_USB_ENUMERATED);
    atomic_store(&b->radio_id, (uint8_t)radio);
    b->baud = default_baud;
    mark_usb_change(b);
}

void bridge_on_usb_unsupported(bridge_t *b, ctrl_radio_id_t radio)
{
    /* NOT ENUMERATED: protocol.md defines that state as "radio attached and
     * CAT interface open". Claiming it here would make the app believe it
     * can talk to a device we never opened. */
    atomic_store(&b->usb_state, (uint8_t)CTRL_USB_ERROR);
    atomic_store(&b->radio_id, (uint8_t)radio);
    b->baud = 0;
    mark_usb_change(b);
}

void bridge_on_usb_disconnected(bridge_t *b)
{
    atomic_store(&b->usb_state, (uint8_t)CTRL_USB_WAITING);
    atomic_store(&b->radio_id, (uint8_t)CTRL_RADIO_NONE);
    /* Stale in-flight data is useless in both directions (§5.5); the
     * failsafe is also cleared — it was armed for the radio that left. */
    ring_purge(&b->rb_ble_to_usb);
    ring_purge(&b->rb_usb_to_ble);
    coal_reset(&b->coal);
    atomic_store(&b->failsafe_len, 0);
    atomic_store(&b->failsafe_fire, false);
    mark_usb_change(b);
}

void bridge_on_usb_error(bridge_t *b)
{
    atomic_store(&b->usb_state, (uint8_t)CTRL_USB_ERROR);
    mark_usb_change(b);
}

/* ---------------------------------------------------------------------- */
/* Control command execution (bridge task context)                         */
/* ---------------------------------------------------------------------- */

static void fill_status(bridge_t *b, ctrl_status_t *s)
{
    s->usb_state = atomic_load(&b->usb_state);
    s->radio_id = atomic_load(&b->radio_id);
    s->baud = b->baud;
    s->drops_usb_to_ble = ring_dropped(&b->rb_usb_to_ble);
    s->drops_ble_to_usb = ring_dropped(&b->rb_ble_to_usb);
    s->fw_major = BRIDGE_FW_MAJOR;
    s->fw_minor = BRIDGE_FW_MINOR;
    s->reset_reason = b->reset_reason;
    s->min_free_heap = b->min_free_heap;
}

static void ctrl_reply(bridge_t *b, const uint8_t *frame, int flen)
{
    if (flen > 0) {
        /* Ctrl replies are small and rare; a failed notify (no subscriber /
         * backpressure) is acceptable — the central retries the command. */
        (void)b->ops.ble_notify_ctrl(b->ops.ctx, frame, (size_t)flen);
    }
}

static bool usb_up(bridge_t *b)
{
    return atomic_load(&b->usb_state) == (uint8_t)CTRL_USB_ENUMERATED;
}

static void exec_ctrl(bridge_t *b, const ctrl_frame_t *f)
{
    uint8_t out[CTRL_FRAME_OVERHEAD + CTRL_STATUS_SIZE];
    uint8_t err = CTRL_ERR_OK;

    switch (f->op) {
    case CTRL_OP_SET_BAUD:
        if (f->len != 4) {
            err = CTRL_ERR_BAD_LEN;
        } else if (!usb_up(b)) {
            err = CTRL_ERR_NO_USB;
        } else {
            uint32_t baud = ctrl_get_u32le(f->payload);
            if (baud < 300 || baud > 3000000) {
                err = CTRL_ERR_BAD_ARG;
            } else if (b->ops.set_baud(b->ops.ctx, baud) != 0) {
                err = CTRL_ERR_BUSY;
            } else {
                b->baud = baud;
                b->status_dirty = true;
            }
        }
        break;

    case CTRL_OP_GET_STATUS: {
        if (f->len != 0) {
            err = CTRL_ERR_BAD_LEN;
            break;
        }
        /* The status frame IS the ack (§4.1). */
        ctrl_status_t s;
        uint8_t payload[CTRL_STATUS_SIZE];
        fill_status(b, &s);
        ctrl_status_encode(&s, payload, sizeof payload);
        int n = ctrl_encode(CTRL_OP_GET_STATUS, payload, CTRL_STATUS_SIZE,
                            out, sizeof out);
        ctrl_reply(b, out, n);
        return;
    }

    case CTRL_OP_USB_RESET:
        if (f->len != 0) {
            err = CTRL_ERR_BAD_LEN;
        } else if (atomic_load(&b->usb_state) == (uint8_t)CTRL_USB_WAITING) {
            err = CTRL_ERR_NO_USB; /* nothing attached to reset (§7.2) */
        } else if (b->ops.usb_reset(b->ops.ctx) != 0) {
            err = CTRL_ERR_BUSY;
        }
        break;

    case CTRL_OP_SET_LINE:
        if (f->len != 1) {
            err = CTRL_ERR_BAD_LEN;
        } else if (!usb_up(b)) {
            err = CTRL_ERR_NO_USB;
        } else if (b->ops.set_line(b->ops.ctx,
                                   (f->payload[0] & CTRL_LINE_DTR) != 0,
                                   (f->payload[0] & CTRL_LINE_RTS) != 0) != 0) {
            err = CTRL_ERR_BUSY;
        }
        break;

    case CTRL_OP_PURGE:
        if (f->len != 1) {
            err = CTRL_ERR_BAD_LEN;
        } else if ((f->payload[0] &
                    ~(CTRL_PURGE_USB_TO_BLE | CTRL_PURGE_BLE_TO_USB)) != 0 ||
                   f->payload[0] == 0) {
            err = CTRL_ERR_BAD_ARG;
        } else {
            if (f->payload[0] & CTRL_PURGE_USB_TO_BLE) {
                ring_purge(&b->rb_usb_to_ble);
                coal_reset(&b->coal);
            }
            if (f->payload[0] & CTRL_PURGE_BLE_TO_USB) {
                ring_purge(&b->rb_ble_to_usb);
            }
        }
        break;

    case CTRL_OP_SET_FAILSAFE:
        if (f->len > CTRL_FAILSAFE_MAX) {
            err = CTRL_ERR_BAD_LEN;
        } else {
            if (f->len) {
                memcpy(b->failsafe, f->payload, f->len);
            }
            atomic_store(&b->failsafe_len, f->len); /* 0 disarms */
        }
        break;

    case CTRL_OP_SET_SPECTRUM:
        /* docs/qmx-panadapter.md §3.2. The synthetic source needs no USB,
         * so NO_USB is reserved for the real I/Q path (plan M4). */
        if (b->ops.ble_notify_spectrum == NULL) {
            err = CTRL_ERR_UNSUPPORTED;
        } else if (f->len != 4) {
            err = CTRL_ERR_BAD_LEN;
        } else if (f->payload[0] > 1u) {
            err = CTRL_ERR_BAD_ARG;
        } else if (f->payload[0] == 0u) {
            b->spec_enabled = false; /* remaining fields ignored */
        } else {
            uint16_t bins = (uint16_t)(f->payload[1] |
                                       ((uint16_t)f->payload[2] << 8));
            uint8_t fps = f->payload[3];
            int nfrags = spec_frag_count(
                bins, atomic_load(&b->mtu_payload));
            if (!spec_valid_bins(bins) || !spec_valid_fps(fps)) {
                err = CTRL_ERR_BAD_ARG;
            } else if (nfrags < 0 || (uint32_t)nfrags * fps >
                                         SPEC_NOTIFY_BUDGET_PER_S) {
                /* Achievability at the LIVE MTU — a silent stall at tiny
                 * MTUs must be a visible error instead (§3.2). */
                err = CTRL_ERR_BAD_ARG;
            } else {
                /* enable while running = reconfigure, never BUSY. */
                b->spec_enabled = true;
                b->spec_bins = bins;
                b->spec_fps = fps;
                b->spec_last_frame_ms = 0;
                b->spec_conn_gen = atomic_load(&b->ble_conn_gen);
            }
        }
        break;

    default:
        err = CTRL_ERR_UNKNOWN_OP;
        break;
    }

    int n = (err == CTRL_ERR_OK)
                ? ctrl_encode_ack(f->op, out, sizeof out)
                : ctrl_encode_nak(f->op, err, out, sizeof out);
    ctrl_reply(b, out, n);
}

static bool pump_ctrl_queue(bridge_t *b)
{
    bool did = false;
    uint8_t reclen;
    while (ring_read(&b->ctrl_q, &reclen, 1) == 1) {
        uint8_t frame[CTRL_MAX_FRAME];
        size_t got = ring_read(&b->ctrl_q, frame, reclen);
        did = true;
        if (got != reclen) {
            break; /* corrupt record — cannot happen with SPSC discipline */
        }
        ctrl_frame_t f;
        int used = ctrl_decode(frame, got, &f);
        if (used <= 0 || (size_t)used != got) {
            /* Truncated/garbage TLV: NAK with the claimed opcode if we have
             * one, so the central always gets exactly one reply. */
            uint8_t out[8];
            int n = ctrl_encode_nak(got ? frame[0] : 0, CTRL_ERR_BAD_LEN, out,
                                    sizeof out);
            ctrl_reply(b, out, n);
            continue;
        }
        exec_ctrl(b, &f);
    }
    return did;
}

/* ---------------------------------------------------------------------- */
/* Datapath pumps (bridge task context)                                    */
/* ---------------------------------------------------------------------- */

static bool pump_failsafe(bridge_t *b)
{
    if (!atomic_load(&b->failsafe_fire)) {
        return false;
    }
    atomic_store(&b->failsafe_fire, false);
    uint8_t len = atomic_load(&b->failsafe_len);
    if (len > 0 && usb_up(b)) {
        /* Emit BEFORE purging so the unkey string can't be discarded (§5.5),
         * then disarm: the failsafe is one-shot. */
        (void)b->ops.usb_tx(b->ops.ctx, b->failsafe, len);
    }
    atomic_store(&b->failsafe_len, 0);
    ring_purge(&b->rb_ble_to_usb);
    return true;
}

static bool pump_ble_to_usb(bridge_t *b)
{
    if (!usb_up(b)) {
        /* No radio: writes can't go anywhere. Drop-and-count so the ring
         * doesn't wedge full forever. */
        size_t n = ring_purge(&b->rb_ble_to_usb);
        return n > 0;
    }
    uint8_t chunk[BRIDGE_USB_TX_CHUNK];
    bool did = false;
    size_t n;
    while ((n = ring_read(&b->rb_ble_to_usb, chunk, sizeof chunk)) > 0) {
        did = true;
        if (b->ops.usb_tx(b->ops.ctx, chunk, n) != 0) {
            break; /* USB backpressure/fault: bytes lost count as link error */
        }
    }
    return did;
}

static bool pump_usb_to_ble(bridge_t *b, uint32_t now)
{
    bool did = false;

    /* Drain ring → staging while there is room. */
    uint8_t tmp[128];
    while (coal_pending(&b->coal) < COAL_BUF_SIZE) {
        size_t room = COAL_BUF_SIZE - coal_pending(&b->coal);
        size_t want = room < sizeof tmp ? room : sizeof tmp;
        size_t n = ring_read(&b->rb_usb_to_ble, tmp, want);
        if (n == 0) {
            break;
        }
        coal_add(&b->coal, tmp, n, now);
        did = true;
    }

    bool connected = atomic_load(&b->ble_connected);
    bool subscribed = atomic_load(&b->ble_cat_subscribed);

    if (!connected || !subscribed) {
        /* §5.5: keep filling for ≤1 s after the central vanishes, then purge
         * — stale CAT responses are useless. */
        if (!b->ble_absent_purged) {
            if (b->ble_absent_since_ms == 0) {
                b->ble_absent_since_ms = now ? now : 1;
            } else if ((uint32_t)(now - b->ble_absent_since_ms) >=
                       BRIDGE_BLE_ABSENT_PURGE_MS) {
                ring_purge(&b->rb_usb_to_ble);
                coal_reset(&b->coal);
                b->ble_absent_purged = true;
            }
        } else {
            ring_purge(&b->rb_usb_to_ble);
            coal_reset(&b->coal);
        }
        return did;
    }
    b->ble_absent_since_ms = 0;
    b->ble_absent_purged = false;

    /* Emit as many notifications as the stack will take this poll. */
    size_t payload_max = atomic_load(&b->mtu_payload);
    for (;;) {
        size_t out_len;
        const uint8_t *p = coal_poll(&b->coal, now, payload_max, &out_len);
        if (p == NULL) {
            break;
        }
        if (b->ops.ble_notify_cat(b->ops.ctx, p, out_len) != 0) {
            break; /* backpressure: retry same bytes next poll (§5.1) */
        }
        coal_consume(&b->coal, out_len);
        did = true;
    }
    return did;
}

static bool pump_events(bridge_t *b, uint32_t now)
{
    bool did = false;
    uint8_t out[CTRL_MAX_FRAME];

    if (b->evt_usb_pending) {
        int n = ctrl_encode_evt_usb(
            (ctrl_usb_state_t)atomic_load(&b->usb_state),
            (ctrl_radio_id_t)atomic_load(&b->radio_id), out, sizeof out);
        ctrl_reply(b, out, n);
        b->evt_usb_pending = false;
        did = true;
    }

    /* Overflow deltas, rate-limited to 1/s per direction pair (§5.4). */
    uint32_t d_u2b = ring_dropped(&b->rb_usb_to_ble);
    uint32_t d_b2u = ring_dropped(&b->rb_ble_to_usb);
    bool have_new = d_u2b != b->reported_drops_u2b ||
                    d_b2u != b->reported_drops_b2u;
    if (have_new && (b->last_ovf_evt_ms == 0 ||
                     (uint32_t)(now - b->last_ovf_evt_ms) >=
                         BRIDGE_OVERFLOW_EVT_MIN_INTERVAL_MS)) {
        if (d_u2b != b->reported_drops_u2b) {
            int n = ctrl_encode_evt_overflow(BRIDGE_OVF_USB_TO_BLE,
                                             d_u2b - b->reported_drops_u2b,
                                             out, sizeof out);
            ctrl_reply(b, out, n);
            b->reported_drops_u2b = d_u2b;
        }
        if (d_b2u != b->reported_drops_b2u) {
            int n = ctrl_encode_evt_overflow(BRIDGE_OVF_BLE_TO_USB,
                                             d_b2u - b->reported_drops_b2u,
                                             out, sizeof out);
            ctrl_reply(b, out, n);
            b->reported_drops_b2u = d_b2u;
        }
        b->last_ovf_evt_ms = now ? now : 1;
        b->status_dirty = true;
        did = true;
    }

    if (b->status_dirty) {
        uint8_t snap[CTRL_STATUS_SIZE];
        bridge_status_read(b, snap, sizeof snap);
        if (memcmp(snap, b->last_status, sizeof snap) != 0) {
            memcpy(b->last_status, snap, sizeof snap);
            (void)b->ops.ble_notify_status(b->ops.ctx, snap, sizeof snap);
            did = true;
        }
        b->status_dirty = false;
    }
    return did;
}

/*
 * Spectrum frame pump (docs/qmx-panadapter.md §3.4): runs LAST in
 * bridge_poll so CAT and CTRL always win the poll's budget. Frames are
 * generated at the configured fps, seq assigned at generation, and sent
 * atomically — if any fragment's notify fails, the rest of the frame is
 * abandoned (drop-newest; the central sees a seq gap). Never retried,
 * never queued.
 */
static bool pump_spectrum(bridge_t *b, uint32_t now)
{
    /* Auto-stop lands here, in poll context where spec_enabled is owned:
     * any disconnect since the enable (generation mismatch) or a USB
     * error kills the stream permanently (until a new SET_SPECTRUM). */
    if (b->spec_enabled &&
        (atomic_load(&b->ble_conn_gen) != b->spec_conn_gen ||
         atomic_load(&b->usb_state) == (uint8_t)CTRL_USB_ERROR)) {
        b->spec_enabled = false;
    }
    if (!b->spec_enabled || b->spec_synth == NULL ||
        !atomic_load(&b->ble_spectrum_subscribed)) {
        return false;
    }
    uint32_t interval = 1000u / b->spec_fps;
    if (b->spec_last_frame_ms != 0 &&
        (uint32_t)(now - b->spec_last_frame_ms) < interval) {
        return false;
    }
    b->spec_last_frame_ms = now ? now : 1;

    static float iq[SPEC_MAX_BINS * 2u];
    static uint8_t bins[SPEC_MAX_BINS];
    static uint8_t frag[COAL_BUF_SIZE];

    spec_synth_fill((spec_synth_t *)b->spec_synth, iq, b->spec_bins);
    spec_compute(iq, b->spec_bins, bins);

    uint8_t seq = b->spec_seq++;
    uint16_t mtu = atomic_load(&b->mtu_payload);
    int nfrags = spec_frag_count(b->spec_bins, mtu);
    if (nfrags < 0) {
        return false; /* MTU collapsed below minimum since enable */
    }
    for (int i = 0; i < nfrags; i++) {
        int n = spec_frag_build(seq, (uint8_t)i, b->spec_bins,
                                BRIDGE_SPEC_SAMPLE_RATE_HZ, bins, mtu,
                                frag, sizeof frag);
        if (n < 0 ||
            b->ops.ble_notify_spectrum(b->ops.ctx, frag, (size_t)n) != 0) {
            return true; /* abandon the frame — atomic, drop-newest */
        }
    }
    return true;
}

bool bridge_poll(bridge_t *b)
{
    uint32_t now = b->ops.now_ms(b->ops.ctx);
    bool did = false;
    did |= pump_failsafe(b); /* first: stuck-PTT protection (§5.5) */
    did |= pump_ctrl_queue(b);
    did |= pump_ble_to_usb(b);
    did |= pump_usb_to_ble(b, now);
    did |= pump_events(b, now);
    did |= pump_spectrum(b, now); /* last: CAT always wins (§3.4) */
    return did;
}

int bridge_status_read(bridge_t *b, uint8_t *out, size_t cap)
{
    ctrl_status_t s;
    fill_status(b, &s);
    return ctrl_status_encode(&s, out, cap);
}
