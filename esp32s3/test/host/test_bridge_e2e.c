/*
 * Host end-to-end simulation (docs/implementation.md §7.4 in spirit):
 * the real bridge_core pumped between
 *   - a fake USB radio with FT-891 (Yaesu) and QMX (Kenwood) personalities,
 *     per-character serial timing and fault injection, and
 *   - a fake BLE central that journals every byte both ways.
 *
 * Everything is deterministic: the test owns the clock (sim.now_ms).
 */
#include <stdio.h>
#include <string.h>

#include "bridge_core.h"
#include "unity.h"

/* ---------------------------------------------------------------------- */
/* Fake radio                                                              */
/* ---------------------------------------------------------------------- */

typedef enum { RADIO_P_FT891, RADIO_P_QMX } radio_pers_t;

typedef struct {
    radio_pers_t pers;
    char cmd[128];       /* accumulating command bytes until ';' */
    size_t cmd_len;
    uint8_t txq[16384];  /* radio → bridge pending bytes (timed release) */
    size_t txq_len;
    size_t txq_sent;
    uint64_t next_byte_us; /* per-character pacing (µs so 38400 ≈ 3.8 B/ms) */
    uint32_t us_per_byte;  /* 10 bits / baud */
    /* Radio state */
    char vfo_a[12];
    int tx;              /* PTT state */
    /* Fault injection */
    int mute;            /* swallow commands, no response */
    int stall_after;     /* emit N bytes of next response then stop */
    /* Journals */
    uint8_t rx_journal[16384]; /* bytes the radio received */
    size_t rx_journal_len;
    uint8_t tx_journal[16384]; /* bytes the radio queued to send */
    size_t tx_journal_len;
} fake_radio_t;

static void radio_init(fake_radio_t *r, radio_pers_t pers, uint32_t baud)
{
    memset(r, 0, sizeof *r);
    r->pers = pers;
    r->us_per_byte = 10u * 1000000u / baud;
    strcpy(r->vfo_a, pers == RADIO_P_FT891 ? "014074000" : "00014074000");
    r->stall_after = -1;
}

static void radio_queue(fake_radio_t *r, const char *s)
{
    size_t n = strlen(s);
    if (r->stall_after >= 0 && n > (size_t)r->stall_after) {
        n = (size_t)r->stall_after; /* partial response then silence */
        r->stall_after = -1;
    }
    TEST_ASSERT_TRUE(r->txq_len + n <= sizeof r->txq);
    TEST_ASSERT_TRUE(r->tx_journal_len + n <= sizeof r->tx_journal);
    memcpy(&r->txq[r->txq_len], s, n);
    r->txq_len += n;
    memcpy(&r->tx_journal[r->tx_journal_len], s, n);
    r->tx_journal_len += n;
}

static void radio_exec_ft891(fake_radio_t *r, const char *cmd)
{
    char out[64];
    if (strcmp(cmd, "ID;") == 0) {
        radio_queue(r, "ID0650;");
    } else if (strcmp(cmd, "FA;") == 0) {
        snprintf(out, sizeof out, "FA%s;", r->vfo_a);
        radio_queue(r, out);
    } else if (strncmp(cmd, "FA", 2) == 0 && strlen(cmd) == 12) {
        memcpy(r->vfo_a, cmd + 2, 9);
        r->vfo_a[9] = '\0'; /* set: no reply, like the real rig */
    } else if (strcmp(cmd, "IF;") == 0) {
        snprintf(out, sizeof out, "IF001%s+000000200000;", r->vfo_a);
        radio_queue(r, out);
    } else if (strcmp(cmd, "TX1;") == 0) {
        r->tx = 1;
    } else if (strcmp(cmd, "TX0;") == 0) {
        r->tx = 0;
    } else if (strcmp(cmd, "TX;") == 0) {
        radio_queue(r, r->tx ? "TX1;" : "TX0;");
    } else {
        radio_queue(r, "?;"); /* Yaesu invalid-command reply */
    }
}

static void radio_exec_qmx(fake_radio_t *r, const char *cmd)
{
    char out[64];
    if (strcmp(cmd, "ID;") == 0) {
        radio_queue(r, "ID020;"); /* TS-480 family */
    } else if (strcmp(cmd, "FA;") == 0) {
        snprintf(out, sizeof out, "FA%s;", r->vfo_a);
        radio_queue(r, out);
    } else if (strncmp(cmd, "FA", 2) == 0 && strlen(cmd) == 14) {
        memcpy(r->vfo_a, cmd + 2, 11); /* Kenwood: 11-digit */
        r->vfo_a[11] = '\0';
    } else if (strcmp(cmd, "TX;") == 0) {
        r->tx = 1;
    } else if (strcmp(cmd, "RX;") == 0) {
        r->tx = 0;
    } else {
        radio_queue(r, "?;");
    }
}

/* Bytes arriving at the radio's UART (bridge usb_tx). */
static void radio_rx(fake_radio_t *r, const uint8_t *d, size_t n)
{
    TEST_ASSERT_TRUE(r->rx_journal_len + n <= sizeof r->rx_journal);
    memcpy(&r->rx_journal[r->rx_journal_len], d, n);
    r->rx_journal_len += n;
    for (size_t i = 0; i < n; i++) {
        if (r->cmd_len < sizeof r->cmd - 1) {
            r->cmd[r->cmd_len++] = (char)d[i];
        }
        if (d[i] == ';') {
            r->cmd[r->cmd_len] = '\0';
            if (!r->mute) {
                if (r->pers == RADIO_P_FT891) {
                    radio_exec_ft891(r, r->cmd);
                } else {
                    radio_exec_qmx(r, r->cmd);
                }
            }
            r->cmd_len = 0;
        }
    }
}

/* Release bytes to the bridge at serial pace. Returns bytes released. */
static size_t radio_tick(fake_radio_t *r, uint32_t now_ms, uint8_t *out,
                         size_t max)
{
    size_t n = 0;
    uint64_t now_us = (uint64_t)now_ms * 1000u;
    while (r->txq_sent < r->txq_len && n < max) {
        if (r->next_byte_us > now_us) {
            break;
        }
        out[n++] = r->txq[r->txq_sent++];
        if (r->next_byte_us + 1000u < now_us) {
            r->next_byte_us = now_us; /* idle gap: restart pacing from now */
        }
        r->next_byte_us += r->us_per_byte;
    }
    if (r->txq_sent == r->txq_len) {
        r->txq_len = r->txq_sent = 0;
    }
    return n;
}

/* ---------------------------------------------------------------------- */
/* Simulation harness: bridge + fake radio + fake central                  */
/* ---------------------------------------------------------------------- */

typedef struct {
    uint32_t now_ms;
    fake_radio_t radio;
    int usb_attached;

    /* Fake central's receive journals */
    uint8_t cat_rx[16384]; /* CAT notifications received */
    size_t cat_rx_len;
    size_t notify_count;
    size_t max_notify_len;
    uint8_t ctrl_rx[8192]; /* CTRL notifications (frames back-to-back) */
    size_t ctrl_rx_len;
    uint8_t status_rx[CTRL_STATUS_SIZE];
    size_t status_updates;

    /* Fault injection */
    int ble_backpressure;   /* fail next N cat notifies */
    int usb_tx_fail;        /* fail usb writes */

    /* Op call recording */
    uint32_t last_set_baud;
    int set_baud_calls;
    int usb_reset_calls;
    int set_line_calls;
    bool last_dtr, last_rts;
} sim_t;

static sim_t S;

static int op_usb_tx(void *ctx, const uint8_t *d, size_t n)
{
    (void)ctx;
    if (!S.usb_attached || S.usb_tx_fail) {
        return -1;
    }
    radio_rx(&S.radio, d, n);
    return 0;
}

static int op_notify_cat(void *ctx, const uint8_t *d, size_t n)
{
    (void)ctx;
    if (S.ble_backpressure > 0) {
        S.ble_backpressure--;
        return -1;
    }
    TEST_ASSERT_TRUE(S.cat_rx_len + n <= sizeof S.cat_rx);
    memcpy(&S.cat_rx[S.cat_rx_len], d, n);
    S.cat_rx_len += n;
    S.notify_count++;
    if (n > S.max_notify_len) {
        S.max_notify_len = n;
    }
    return 0;
}

static int op_notify_ctrl(void *ctx, const uint8_t *d, size_t n)
{
    (void)ctx;
    TEST_ASSERT_TRUE(S.ctrl_rx_len + n <= sizeof S.ctrl_rx);
    memcpy(&S.ctrl_rx[S.ctrl_rx_len], d, n);
    S.ctrl_rx_len += n;
    return 0;
}

static int op_notify_status(void *ctx, const uint8_t *d, size_t n)
{
    (void)ctx;
    TEST_ASSERT_EQUAL_size_t(CTRL_STATUS_SIZE, n);
    memcpy(S.status_rx, d, n);
    S.status_updates++;
    return 0;
}

static int op_set_baud(void *ctx, uint32_t baud)
{
    (void)ctx;
    S.last_set_baud = baud;
    S.set_baud_calls++;
    return 0;
}

static int op_set_line(void *ctx, bool dtr, bool rts)
{
    (void)ctx;
    S.set_line_calls++;
    S.last_dtr = dtr;
    S.last_rts = rts;
    return 0;
}

static int op_usb_reset(void *ctx)
{
    (void)ctx;
    S.usb_reset_calls++;
    return 0;
}

static uint32_t op_now_ms(void *ctx)
{
    (void)ctx;
    return S.now_ms;
}

static const bridge_ops_t OPS = {
    .usb_tx = op_usb_tx,
    .ble_notify_cat = op_notify_cat,
    .ble_notify_ctrl = op_notify_ctrl,
    .ble_notify_status = op_notify_status,
    .set_baud = op_set_baud,
    .set_line = op_set_line,
    .usb_reset = op_usb_reset,
    .now_ms = op_now_ms,
    .ctx = NULL,
};

static bridge_t B;
static uint8_t rb_u2b[BRIDGE_RB_USB_TO_BLE_CAP];
static uint8_t rb_b2u[BRIDGE_RB_BLE_TO_USB_CAP];

/* Advance simulated time, pumping radio + bridge every millisecond. */
static void sim_run_ms(uint32_t ms)
{
    for (uint32_t i = 0; i < ms; i++) {
        S.now_ms++;
        if (S.usb_attached) {
            uint8_t out[64];
            size_t n = radio_tick(&S.radio, S.now_ms, out, sizeof out);
            if (n) {
                bridge_on_usb_rx(&B, out, n);
            }
        }
        bridge_poll(&B);
    }
}

static void sim_setup(radio_pers_t pers, uint32_t baud, uint16_t att_mtu)
{
    memset(&S, 0, sizeof S);
    radio_init(&S.radio, pers, baud);
    S.usb_attached = 1;
    bridge_init(&B, &OPS, rb_u2b, sizeof rb_u2b, rb_b2u, sizeof rb_b2u);
    bridge_on_usb_connected(&B,
                            pers == RADIO_P_FT891 ? CTRL_RADIO_FT891
                                                  : CTRL_RADIO_QMX_CDC,
                            baud);
    bridge_on_ble_connected(&B);
    bridge_on_ble_cat_subscribed(&B, true);
    bridge_set_mtu(&B, att_mtu);
    sim_run_ms(5); /* settle: initial status + EVT_USB */
}

/* Central sends a CAT command (as CAT_RX writes, possibly split). */
static void central_send(const char *s)
{
    bridge_on_ble_cat_write(&B, (const uint8_t *)s, strlen(s));
}

/* Wait until the CAT journal bytes received at/after `from` end with
 * `expect` (or timeout). Anchoring at `from` prevents a stale identical
 * response from producing a false match. */
static int central_expect_from(size_t from, const char *expect,
                               uint32_t timeout_ms)
{
    size_t want = strlen(expect);
    uint32_t deadline = S.now_ms + timeout_ms;
    while (S.now_ms < deadline) {
        sim_run_ms(1);
        if (S.cat_rx_len >= from + want &&
            memcmp(&S.cat_rx[S.cat_rx_len - want], expect, want) == 0) {
            return 1;
        }
    }
    return 0;
}

static int central_expect(const char *expect, uint32_t timeout_ms)
{
    return central_expect_from(S.cat_rx_len, expect, timeout_ms);
}

/* Find last CTRL frame with a given opcode; returns record len or -1. */
static int last_ctrl_frame(uint8_t op, ctrl_frame_t *out)
{
    size_t off = 0;
    int found = -1;
    ctrl_frame_t f;
    while (off < S.ctrl_rx_len) {
        int used = ctrl_decode(&S.ctrl_rx[off], S.ctrl_rx_len - off, &f);
        if (used <= 0) {
            break;
        }
        if (f.op == op) {
            *out = f;
            found = used;
        }
        off += (size_t)used;
    }
    return found;
}

void setUp(void) {}
void tearDown(void) {}

/* ---------------------------------------------------------------------- */
/* Tests                                                                   */
/* ---------------------------------------------------------------------- */

static void test_ft891_poll_cycle_transparent(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);

    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID0650;", 100));

    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA014074000;", 100));

    central_send("FA014250000;"); /* set frequency (no reply) */
    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA014250000;", 100));

    central_send("TX1;");
    central_send("TX;");
    TEST_ASSERT_TRUE(central_expect("TX1;", 100));
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx);
    central_send("TX0;");
    sim_run_ms(50);
    TEST_ASSERT_EQUAL_INT(0, S.radio.tx);

    /* Byte-perfect transparency: everything the radio queued arrived, in
     * order, unmodified (§7.4 journaling check). */
    TEST_ASSERT_EQUAL_size_t(S.radio.tx_journal_len, S.cat_rx_len);
    TEST_ASSERT_EQUAL_MEMORY(S.radio.tx_journal, S.cat_rx, S.cat_rx_len);
    /* And the radio saw exactly what the central wrote. */
    TEST_ASSERT_EQUAL_STRING_LEN("ID;FA;FA014250000;FA;TX1;TX;TX0;",
                                 (const char *)S.radio.rx_journal,
                                 S.radio.rx_journal_len);
}

static void test_qmx_dialect_transparent(void)
{
    sim_setup(RADIO_P_QMX, 38400, 185);

    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID020;", 100));

    central_send("FA00007074000;"); /* Kenwood 11-digit set */
    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA00007074000;", 100));

    central_send("TX;");
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx);
    central_send("RX;");
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(0, S.radio.tx);
}

static void test_chunking_small_mtu(void)
{
    /* 23-byte MTU → 20-byte payloads: a 12-byte response must arrive intact;
     * a long burst must arrive in ≤20-byte notifications, byte-perfect. */
    sim_setup(RADIO_P_FT891, 38400, 23);

    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA014074000;", 200));
    TEST_ASSERT_TRUE(S.max_notify_len <= 20);

    for (int i = 0; i < 10; i++) {
        central_send("IF;");
    }
    sim_run_ms(400);
    TEST_ASSERT_EQUAL_size_t(S.radio.tx_journal_len, S.cat_rx_len);
    TEST_ASSERT_EQUAL_MEMORY(S.radio.tx_journal, S.cat_rx, S.cat_rx_len);
    TEST_ASSERT_TRUE(S.max_notify_len <= 20);
}

static void test_latency_bound_semicolon_flush(void)
{
    /* The ';' flush means a short response completes without waiting for
     * the idle timer: at 38400 baud a 7-byte reply spans ~7 ms of paced
     * release here; require completion well before the idle path would. */
    sim_setup(RADIO_P_FT891, 38400, 185);
    uint32_t t0 = S.now_ms;
    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID0650;", 100));
    uint32_t elapsed = S.now_ms - t0;
    TEST_ASSERT_TRUE_MESSAGE(elapsed <= 7 + 3, "response latency too high");
}

static void test_ctrl_get_status_and_set_baud(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);

    /* GET_STATUS → one CTRL frame carrying the status payload (§4.1). */
    uint8_t cmd[2] = { CTRL_OP_GET_STATUS, 0 };
    bridge_on_ctrl_write(&B, cmd, sizeof cmd);
    sim_run_ms(2);
    ctrl_frame_t f;
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_GET_STATUS, &f) > 0);
    ctrl_status_t st;
    TEST_ASSERT_EQUAL_INT(0, ctrl_status_decode(f.payload, f.len, &st));
    TEST_ASSERT_EQUAL_UINT8(CTRL_USB_ENUMERATED, st.usb_state);
    TEST_ASSERT_EQUAL_UINT8(CTRL_RADIO_FT891, st.radio_id);
    TEST_ASSERT_EQUAL_UINT32(4800, st.baud);

    /* SET_BAUD 38400 → ACK + op called + status change notified. */
    uint8_t sb[6] = { CTRL_OP_SET_BAUD, 4, 0, 0, 0, 0 };
    ctrl_put_u32le(&sb[2], 38400);
    size_t status_before = S.status_updates;
    bridge_on_ctrl_write(&B, sb, sizeof sb);
    sim_run_ms(2);
    TEST_ASSERT_EQUAL_INT(1, S.set_baud_calls);
    TEST_ASSERT_EQUAL_UINT32(38400, S.last_set_baud);
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_ACK, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_SET_BAUD, f.payload[0]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_OK, f.payload[1]);
    TEST_ASSERT_TRUE(S.status_updates > status_before);

    /* Bad length → NAK BAD_LEN, op not called again. */
    uint8_t bad[3] = { CTRL_OP_SET_BAUD, 1, 42 };
    bridge_on_ctrl_write(&B, bad, sizeof bad);
    sim_run_ms(2);
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_NAK, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_SET_BAUD, f.payload[0]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_LEN, f.payload[1]);
    TEST_ASSERT_EQUAL_INT(1, S.set_baud_calls);

    /* Unknown opcode → NAK UNKNOWN_OP. */
    uint8_t unk[2] = { 0x55, 0 };
    bridge_on_ctrl_write(&B, unk, sizeof unk);
    sim_run_ms(2);
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_NAK, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(0x55, f.payload[0]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_UNKNOWN_OP, f.payload[1]);
}

static void test_set_line_and_usb_reset(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);
    uint8_t sl[3] = { CTRL_OP_SET_LINE, 1, CTRL_LINE_RTS };
    bridge_on_ctrl_write(&B, sl, sizeof sl);
    sim_run_ms(2);
    TEST_ASSERT_EQUAL_INT(1, S.set_line_calls);
    TEST_ASSERT_FALSE(S.last_dtr);
    TEST_ASSERT_TRUE(S.last_rts);

    uint8_t ur[2] = { CTRL_OP_USB_RESET, 0 };
    bridge_on_ctrl_write(&B, ur, sizeof ur);
    sim_run_ms(2);
    TEST_ASSERT_EQUAL_INT(1, S.usb_reset_calls);
}

static void test_failsafe_fires_on_disconnect(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);

    /* App keys PTT after arming the failsafe (§6). */
    uint8_t fs[6] = { CTRL_OP_SET_FAILSAFE, 4, 'T', 'X', '0', ';' };
    bridge_on_ctrl_write(&B, fs, sizeof fs);
    central_send("TX1;");
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx);

    /* BLE central dies mid-transmit → radio must unkey. */
    bridge_on_ble_disconnected(&B);
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(0, S.radio.tx);

    /* One-shot: reconnect, key again, disconnect → no second emission. */
    size_t seen = S.radio.rx_journal_len;
    bridge_on_ble_connected(&B);
    bridge_on_ble_cat_subscribed(&B, true);
    central_send("TX1;");
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx);
    bridge_on_ble_disconnected(&B);
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx); /* disarmed: stays keyed */
    TEST_ASSERT_EQUAL_size_t(seen + 4, S.radio.rx_journal_len); /* only TX1; */
}

static void test_failsafe_disarm(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);
    uint8_t fs[6] = { CTRL_OP_SET_FAILSAFE, 4, 'T', 'X', '0', ';' };
    bridge_on_ctrl_write(&B, fs, sizeof fs);
    sim_run_ms(2);
    uint8_t disarm[2] = { CTRL_OP_SET_FAILSAFE, 0 };
    bridge_on_ctrl_write(&B, disarm, sizeof disarm);
    central_send("TX1;");
    sim_run_ms(20);
    bridge_on_ble_disconnected(&B);
    sim_run_ms(20);
    TEST_ASSERT_EQUAL_INT(1, S.radio.tx); /* clean disarm honored */
}

static void test_overflow_reported_with_rate_limit(void)
{
    sim_setup(RADIO_P_FT891, 38400, 185);
    /* Central subscribed but permanently backpressured: rb_usb_to_ble and
     * staging fill up and overflow. */
    S.ble_backpressure = 1000000;
    for (int i = 0; i < 200; i++) {
        radio_queue(&S.radio, "IF001014074000+000000200000;");
    }
    sim_run_ms(3000);
    S.ble_backpressure = 0;

    ctrl_frame_t f;
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_EVT_OVERFLOW, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(BRIDGE_OVF_USB_TO_BLE, f.payload[0]);
    TEST_ASSERT_TRUE(ctrl_get_u32le(&f.payload[1]) > 0);

    /* Rate limit: with ~3 s of continuous overflow, at most ~4 events. */
    size_t evt_count = 0, off = 0;
    ctrl_frame_t g;
    while (off < S.ctrl_rx_len) {
        int used = ctrl_decode(&S.ctrl_rx[off], S.ctrl_rx_len - off, &g);
        if (used <= 0) {
            break;
        }
        if (g.op == CTRL_OP_EVT_OVERFLOW) {
            evt_count++;
        }
        off += (size_t)used;
    }
    TEST_ASSERT_TRUE(evt_count >= 1 && evt_count <= 4);
}

static void test_ble_backpressure_no_loss(void)
{
    /* §5.1: transient notify failures must never lose bytes. */
    sim_setup(RADIO_P_FT891, 38400, 185);
    S.ble_backpressure = 5; /* first 5 notify attempts fail */
    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA014074000;", 200));
    TEST_ASSERT_EQUAL_size_t(S.radio.tx_journal_len, S.cat_rx_len);
    TEST_ASSERT_EQUAL_MEMORY(S.radio.tx_journal, S.cat_rx, S.cat_rx_len);
}

static void test_usb_detach_recovery(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);
    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID0650;", 100));

    /* Cable pull mid-session. */
    S.usb_attached = 0;
    bridge_on_usb_disconnected(&B);
    sim_run_ms(10);
    ctrl_frame_t f;
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_EVT_USB, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_USB_WAITING, f.payload[0]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_RADIO_NONE, f.payload[1]);

    /* Writes while detached are absorbed (dropped), not wedged. */
    central_send("FA;");
    sim_run_ms(10);

    /* Re-attach: auto-recovery, fresh radio state. */
    radio_init(&S.radio, RADIO_P_FT891, 4800);
    S.usb_attached = 1;
    bridge_on_usb_connected(&B, CTRL_RADIO_FT891, 4800);
    sim_run_ms(5);
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_EVT_USB, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_USB_ENUMERATED, f.payload[0]);

    size_t before = S.cat_rx_len;
    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID0650;", 100));
    TEST_ASSERT_TRUE(S.cat_rx_len > before);
}

static void test_ble_absent_purge_after_1s(void)
{
    sim_setup(RADIO_P_FT891, 38400, 185);
    bridge_on_ble_disconnected(&B);

    /* Radio chatters while no central is connected. */
    radio_queue(&S.radio, "FA014074000;");
    sim_run_ms(1500); /* > 1 s grace (§5.5) */
    radio_queue(&S.radio, "FA014074000;");
    sim_run_ms(100);

    /* Central reconnects: no stale bytes may be delivered. */
    size_t before = S.cat_rx_len;
    bridge_on_ble_connected(&B);
    bridge_on_ble_cat_subscribed(&B, true);
    sim_run_ms(50);
    TEST_ASSERT_EQUAL_size_t(before, S.cat_rx_len);

    /* Fresh traffic flows normally again. */
    central_send("ID;");
    TEST_ASSERT_TRUE(central_expect("ID0650;", 100));
}

static void test_radio_mute_fault(void)
{
    /* No-response fault: nothing arrives, nothing corrupts, and the link
     * still works when the radio recovers. */
    sim_setup(RADIO_P_FT891, 4800, 185);
    S.radio.mute = 1;
    central_send("FA;");
    sim_run_ms(300);
    TEST_ASSERT_EQUAL_size_t(0, S.cat_rx_len);
    S.radio.mute = 0;
    central_send("FA;");
    TEST_ASSERT_TRUE(central_expect("FA014074000;", 100));
}

static void test_radio_stall_fault_partial_response(void)
{
    /* Partial response then stall: the partial bytes arrive (idle flush) so
     * the app's timeout logic sees exactly what the radio sent. */
    sim_setup(RADIO_P_FT891, 4800, 185);
    S.radio.stall_after = 3; /* only "FA0" of the reply */
    central_send("FA;");
    sim_run_ms(300);
    TEST_ASSERT_EQUAL_size_t(3, S.cat_rx_len);
    TEST_ASSERT_EQUAL_MEMORY("FA0", S.cat_rx, 3);
}

static void test_purge_command(void)
{
    sim_setup(RADIO_P_FT891, 4800, 185);
    /* Wedge the USB writer so central writes sit in the b2u ring, purge,
     * then unwedge: the radio must never see the purged commands. */
    S.usb_tx_fail = 1;
    central_send("FA;FA;FA;");
    uint8_t pg[3] = { CTRL_OP_PURGE, 1, CTRL_PURGE_BLE_TO_USB };
    bridge_on_ctrl_write(&B, pg, sizeof pg);
    sim_run_ms(2);
    S.usb_tx_fail = 0;
    size_t rx_before = S.radio.rx_journal_len;
    sim_run_ms(50);
    TEST_ASSERT_EQUAL_size_t(rx_before, S.radio.rx_journal_len);

    /* Invalid purge mask → NAK BAD_ARG. */
    uint8_t bad[3] = { CTRL_OP_PURGE, 1, 0xF0 };
    bridge_on_ctrl_write(&B, bad, sizeof bad);
    sim_run_ms(2);
    ctrl_frame_t f;
    TEST_ASSERT_TRUE(last_ctrl_frame(CTRL_OP_NAK, &f) > 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, f.payload[1]);
}

static void test_soak_1000_commands_journaled(void)
{
    /* §7.4: 1000-command sequence with journal comparison on both ends. */
    sim_setup(RADIO_P_FT891, 38400, 185);
    static char expect_radio_rx[8192];
    size_t exp_len = 0;
    for (int i = 0; i < 1000; i++) {
        const char *cmd = (i % 3 == 0) ? "IF;" : (i % 3 == 1) ? "FA;" : "TX;";
        central_send(cmd);
        memcpy(&expect_radio_rx[exp_len], cmd, strlen(cmd));
        exp_len += strlen(cmd);
        sim_run_ms(12); /* ~83 cmd/s, well within the serial budget */
        /* Journals are bounded: compare + reset incrementally, but only at
         * a fully-drained instant so no in-flight bytes straddle the cut. */
        if (S.radio.tx_journal_len > 12000 && S.radio.txq_len == 0 &&
            ring_used(&B.rb_usb_to_ble) == 0 && coal_pending(&B.coal) == 0) {
            TEST_ASSERT_EQUAL_size_t(S.radio.tx_journal_len, S.cat_rx_len);
            TEST_ASSERT_EQUAL_MEMORY(S.radio.tx_journal, S.cat_rx,
                                     S.cat_rx_len);
            S.radio.tx_journal_len = 0;
            S.cat_rx_len = 0;
        }
    }
    sim_run_ms(500);
    TEST_ASSERT_EQUAL_size_t(S.radio.tx_journal_len, S.cat_rx_len);
    TEST_ASSERT_EQUAL_MEMORY(S.radio.tx_journal, S.cat_rx, S.cat_rx_len);
    /* Radio-side journal: it received exactly the 1000 commands, in order. */
    TEST_ASSERT_EQUAL_size_t(exp_len, S.radio.rx_journal_len);
    TEST_ASSERT_EQUAL_MEMORY(expect_radio_rx, S.radio.rx_journal, exp_len);
    TEST_ASSERT_EQUAL_UINT32(0, ring_dropped(&B.rb_usb_to_ble));
    TEST_ASSERT_EQUAL_UINT32(0, ring_dropped(&B.rb_ble_to_usb));
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_ft891_poll_cycle_transparent);
    RUN_TEST(test_qmx_dialect_transparent);
    RUN_TEST(test_chunking_small_mtu);
    RUN_TEST(test_latency_bound_semicolon_flush);
    RUN_TEST(test_ctrl_get_status_and_set_baud);
    RUN_TEST(test_set_line_and_usb_reset);
    RUN_TEST(test_failsafe_fires_on_disconnect);
    RUN_TEST(test_failsafe_disarm);
    RUN_TEST(test_overflow_reported_with_rate_limit);
    RUN_TEST(test_ble_backpressure_no_loss);
    RUN_TEST(test_usb_detach_recovery);
    RUN_TEST(test_ble_absent_purge_after_1s);
    RUN_TEST(test_radio_mute_fault);
    RUN_TEST(test_radio_stall_fault_partial_response);
    RUN_TEST(test_purge_command);
    RUN_TEST(test_soak_1000_commands_journaled);
    return UNITY_END();
}
