/* Host tests for the panadapter spectrum path (docs/qmx-panadapter.md §7):
 * DSP invariants, fragmentation at MTU boundaries, SET_SPECTRUM validation
 * through the real bridge, and an end-to-end generate→fragment→drop run. */
#include <math.h>
#include <string.h>

#include "bridge_core.h"
#include "ctrl_proto.h"
#include "spectrum.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

/* --- Validation ---------------------------------------------------------- */

static void test_valid_bins_and_fps(void)
{
    TEST_ASSERT_TRUE(spec_valid_bins(64));
    TEST_ASSERT_TRUE(spec_valid_bins(512));
    TEST_ASSERT_FALSE(spec_valid_bins(0));
    TEST_ASSERT_FALSE(spec_valid_bins(100));
    TEST_ASSERT_FALSE(spec_valid_bins(1024));
    TEST_ASSERT_TRUE(spec_valid_fps(1));
    TEST_ASSERT_TRUE(spec_valid_fps(30));
    TEST_ASSERT_FALSE(spec_valid_fps(0));
    TEST_ASSERT_FALSE(spec_valid_fps(31));
}

/* --- Fragmentation -------------------------------------------------------- */

static void test_frag_count_boundaries(void)
{
    /* MTU 244 (ATT 247): 256 bins → frag0 carries 232, frag1 the rest. */
    TEST_ASSERT_EQUAL_INT(2, spec_frag_count(256, 244));
    /* 512 bins @ 244: 232 + 239 + 41 → 3 fragments. */
    TEST_ASSERT_EQUAL_INT(3, spec_frag_count(512, 244));
    /* Everything fits in one when small enough. */
    TEST_ASSERT_EQUAL_INT(1, spec_frag_count(64, 244));
    /* Minimum MTU is enforced, not finessed. */
    TEST_ASSERT_EQUAL_INT(-1, spec_frag_count(64, 31));
    /* At exactly the minimum, the math still holds. */
    int n = spec_frag_count(512, 32);
    TEST_ASSERT_TRUE(n > 0);
}

static void test_frag_build_golden_small_mtu(void)
{
    /* 64 bins at mtu_payload 32: frag0 carries 20, then 27, then 17. */
    uint8_t bins[64];
    for (int i = 0; i < 64; i++) {
        bins[i] = (uint8_t)i;
    }
    TEST_ASSERT_EQUAL_INT(3, spec_frag_count(64, 32));

    uint8_t out[64];
    int n = spec_frag_build(7, 0, 64, 48000, bins, 32, out, sizeof out);
    TEST_ASSERT_EQUAL_INT(32, n);
    const uint8_t frag0_hdr[] = { 7, 0, 3, SPEC_FLAGS_V1, 0x00, 0x00,
                                  0x40, 0x00, 0x80, 0xBB, 0x00, 0x00 };
    TEST_ASSERT_EQUAL_MEMORY(frag0_hdr, out, sizeof frag0_hdr);
    TEST_ASSERT_EQUAL_UINT8(0, out[12]);   /* first bin byte */
    TEST_ASSERT_EQUAL_UINT8(19, out[31]);  /* last of 20 */

    n = spec_frag_build(7, 1, 64, 48000, bins, 32, out, sizeof out);
    TEST_ASSERT_EQUAL_INT(32, n);
    TEST_ASSERT_EQUAL_UINT8(1, out[1]);
    TEST_ASSERT_EQUAL_UINT8(20, out[3]);   /* first_bin lo */
    TEST_ASSERT_EQUAL_UINT8(0, out[4]);
    TEST_ASSERT_EQUAL_UINT8(20, out[5]);
    TEST_ASSERT_EQUAL_UINT8(46, out[31]);

    n = spec_frag_build(7, 2, 64, 48000, bins, 32, out, sizeof out);
    TEST_ASSERT_EQUAL_INT(5 + 17, n);
    TEST_ASSERT_EQUAL_UINT8(47, out[3]);
    TEST_ASSERT_EQUAL_UINT8(63, out[21]);

    /* One past the end and short buffers refuse. */
    TEST_ASSERT_EQUAL_INT(-1,
        spec_frag_build(7, 3, 64, 48000, bins, 32, out, sizeof out));
    TEST_ASSERT_EQUAL_INT(-1,
        spec_frag_build(7, 0, 64, 48000, bins, 32, out, 10));
}

/* --- DSP ------------------------------------------------------------------ */

static void test_fullscale_tone_reads_zero_dbfs(void)
{
    /* A full-scale complex exponential k cycles per window lands at
     * shifted bin N/2 + k with (near) 0 dBFS. */
    enum { N = 128, K = 16 };
    static float iq[N * 2];
    for (int i = 0; i < N; i++) {
        double ph = 2.0 * M_PI * K * i / N;
        iq[2 * i] = (float)cos(ph);
        iq[2 * i + 1] = (float)sin(ph);
    }
    uint8_t bins[N];
    spec_compute(iq, N, bins);
    int peak = N / 2 + K;
    /* 0 dBFS quantised = 0..2 (scalloping-free bin, small numeric slop). */
    TEST_ASSERT_TRUE(bins[peak] <= 2);
    /* Away from the peak the Hann skirt is far down. */
    TEST_ASSERT_TRUE(bins[peak + 8] > 100);
    TEST_ASSERT_TRUE(bins[8] > 100);
}

static void test_negative_frequency_lands_below_centre(void)
{
    enum { N = 128, K = 12 };
    static float iq[N * 2];
    for (int i = 0; i < N; i++) {
        double ph = -2.0 * M_PI * K * i / N; /* negative frequency */
        iq[2 * i] = (float)cos(ph);
        iq[2 * i + 1] = (float)sin(ph);
    }
    uint8_t bins[N];
    spec_compute(iq, N, bins);
    TEST_ASSERT_TRUE(bins[N / 2 - K] <= 2);
}

static void test_dc_offset_is_removed(void)
{
    /* A pure DC input (the direct-conversion offset) must NOT paint a
     * carrier at the centre bin (docs/qmx-panadapter.md §3.3). */
    enum { N = 128 };
    static float iq[N * 2];
    for (int i = 0; i < N; i++) {
        iq[2 * i] = 0.5f;
        iq[2 * i + 1] = -0.25f;
    }
    uint8_t bins[N];
    spec_compute(iq, N, bins);
    TEST_ASSERT_TRUE(bins[N / 2] > 200); /* silence, not a spike */
}

static void test_synth_sweep_is_deterministic_and_visible(void)
{
    spec_synth_t a;
    spec_synth_t b;
    spec_synth_init(&a, 0x51CA);
    spec_synth_init(&b, 0x51CA);
    static float iqa[256 * 2];
    static float iqb[256 * 2];
    spec_synth_fill(&a, iqa, 256);
    spec_synth_fill(&b, iqb, 256);
    TEST_ASSERT_EQUAL_MEMORY(iqa, iqb, sizeof iqa);

    uint8_t bins[256];
    spec_compute(iqa, 256, bins);
    int min = 255;
    for (int i = 0; i < 256; i++) {
        if (bins[i] < min) {
            min = bins[i];
        }
    }
    /* -20 dBFS tone → quantised ≈ 40 somewhere in the span. */
    TEST_ASSERT_TRUE(min > 20 && min < 60);
}

/* --- SET_SPECTRUM through the real bridge --------------------------------- */

typedef struct {
    uint8_t last_ctrl[CTRL_MAX_FRAME];
    int last_ctrl_len;
    uint8_t spec_frames[64][COAL_BUF_SIZE];
    int spec_lens[64];
    int spec_count;
    int fail_spectrum_after; /* -1 = never fail */
    uint32_t now;
} fix_t;

static int fx_usb_tx(void *c, const uint8_t *d, size_t n)
{ (void)c; (void)d; (void)n; return 0; }
static int fx_notify_cat(void *c, const uint8_t *d, size_t n)
{ (void)c; (void)d; (void)n; return 0; }
static int fx_notify_ctrl(void *c, const uint8_t *d, size_t n)
{
    fix_t *f = (fix_t *)c;
    memcpy(f->last_ctrl, d, n);
    f->last_ctrl_len = (int)n;
    return 0;
}
static int fx_notify_status(void *c, const uint8_t *d, size_t n)
{ (void)c; (void)d; (void)n; return 0; }
static int fx_notify_spectrum(void *c, const uint8_t *d, size_t n)
{
    fix_t *f = (fix_t *)c;
    if (f->fail_spectrum_after >= 0 && f->spec_count >= f->fail_spectrum_after) {
        return -1;
    }
    if (f->spec_count < 64) {
        memcpy(f->spec_frames[f->spec_count], d, n);
        f->spec_lens[f->spec_count] = (int)n;
    }
    f->spec_count++;
    return 0;
}
static int fx_set_baud(void *c, uint32_t b) { (void)c; (void)b; return 0; }
static int fx_set_line(void *c, bool d, bool r)
{ (void)c; (void)d; (void)r; return 0; }
static int fx_usb_reset(void *c) { (void)c; return 0; }
static uint32_t fx_now(void *c) { return ((fix_t *)c)->now; }

static bridge_t s_b;
static fix_t s_fx;
static spec_synth_t s_synth;
static uint8_t s_u2b[2048];
static uint8_t s_b2u[2048];

static void make_bridge(bool with_spectrum)
{
    memset(&s_fx, 0, sizeof s_fx);
    s_fx.fail_spectrum_after = -1;
    s_fx.now = 1000;
    bridge_ops_t ops = {
        .usb_tx = fx_usb_tx,
        .ble_notify_cat = fx_notify_cat,
        .ble_notify_ctrl = fx_notify_ctrl,
        .ble_notify_status = fx_notify_status,
        .ble_notify_spectrum = with_spectrum ? fx_notify_spectrum : NULL,
        .set_baud = fx_set_baud,
        .set_line = fx_set_line,
        .usb_reset = fx_usb_reset,
        .now_ms = fx_now,
        .ctx = &s_fx,
    };
    bridge_init(&s_b, &ops, s_u2b, sizeof s_u2b, s_b2u, sizeof s_b2u);
    spec_synth_init(&s_synth, 1);
    s_b.spec_synth = &s_synth;
    bridge_on_ble_connected(&s_b);
    bridge_set_mtu(&s_b, 247);
    bridge_on_spectrum_subscribed(&s_b, true);
}

static void send_set_spectrum(uint8_t enable, uint16_t bins, uint8_t fps)
{
    uint8_t payload[4] = { enable, (uint8_t)(bins & 0xFF),
                           (uint8_t)(bins >> 8), fps };
    uint8_t frame[CTRL_MAX_FRAME];
    int n = ctrl_encode(CTRL_OP_SET_SPECTRUM, payload, 4, frame,
                        sizeof frame);
    bridge_on_ctrl_write(&s_b, frame, (size_t)n);
    bridge_poll(&s_b);
}

static uint8_t last_reply_op(void) { return s_fx.last_ctrl[0]; }
static uint8_t last_reply_err(void) { return s_fx.last_ctrl[3]; }

static void test_set_spectrum_unsupported_without_dsp(void)
{
    make_bridge(false);
    send_set_spectrum(1, 256, 15);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_NAK, last_reply_op());
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_UNSUPPORTED, last_reply_err());
}

static void test_set_spectrum_validation(void)
{
    make_bridge(true);
    send_set_spectrum(1, 100, 15); /* bins not in the set */
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_NAK, last_reply_op());
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, last_reply_err());
    send_set_spectrum(1, 256, 0);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, last_reply_err());
    send_set_spectrum(2, 256, 15);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, last_reply_err());
    /* Achievability at the live MTU: tiny MTU × max ask must refuse
     * rather than silently stall (docs/qmx-panadapter.md §3.2). */
    bridge_set_mtu(&s_b, 35);
    send_set_spectrum(1, 512, 30);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_NAK, last_reply_op());
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, last_reply_err());
    /* The same ask at a healthy MTU is fine. */
    bridge_set_mtu(&s_b, 247);
    send_set_spectrum(1, 256, 15);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_ACK, last_reply_op());
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_OK, last_reply_err());
}

static void test_frames_flow_and_seq_increments(void)
{
    make_bridge(true);
    send_set_spectrum(1, 256, 15);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_ACK, last_reply_op());
    for (int t = 0; t < 10; t++) {
        s_fx.now += 67;
        bridge_poll(&s_b);
    }
    /* 10 ticks ≥ one interval each → ~10 frames × 2 fragments. */
    TEST_ASSERT_TRUE(s_fx.spec_count >= 16);
    /* Fragment 0 of the first two frames: seq increments. */
    TEST_ASSERT_EQUAL_UINT8(0, s_fx.spec_frames[0][1]);
    uint8_t seq0 = s_fx.spec_frames[0][0];
    uint8_t seq1 = s_fx.spec_frames[2][0];
    TEST_ASSERT_EQUAL_UINT8((uint8_t)(seq0 + 1), seq1);
    /* Header sanity: flags v1, 256 bins, 48 kHz. */
    TEST_ASSERT_EQUAL_UINT8(SPEC_FLAGS_V1, s_fx.spec_frames[0][3]);
    TEST_ASSERT_EQUAL_UINT16(256, (uint16_t)(s_fx.spec_frames[0][6]
                                  | (s_fx.spec_frames[0][7] << 8)));
}

static void test_dropped_frame_leaves_seq_gap_and_no_partial(void)
{
    make_bridge(true);
    /* Enable emits the first frame immediately (2 fragments @ 256 bins). */
    send_set_spectrum(1, 256, 15);
    TEST_ASSERT_EQUAL_INT(2, s_fx.spec_count);
    uint8_t seq_a = s_fx.spec_frames[0][0];

    /* Next frame: the FIRST fragment fails → nothing more of that frame
     * is sent (atomic drop; docs/qmx-panadapter.md §3.4). */
    s_fx.fail_spectrum_after = 2;
    s_fx.now += 67;
    bridge_poll(&s_b);
    TEST_ASSERT_EQUAL_INT(2, s_fx.spec_count); /* nothing new delivered */

    /* Restore and pump another frame: the central sees a seq GAP. */
    s_fx.fail_spectrum_after = -1;
    s_fx.now += 67;
    bridge_poll(&s_b);
    TEST_ASSERT_EQUAL_INT(4, s_fx.spec_count);
    uint8_t seq_c = s_fx.spec_frames[2][0];
    TEST_ASSERT_EQUAL_UINT8((uint8_t)(seq_a + 2), seq_c);
}

static void test_disable_and_disconnect_stop_streaming(void)
{
    make_bridge(true);
    send_set_spectrum(1, 64, 30); /* first frame lands with the enable */
    s_fx.now += 40;
    bridge_poll(&s_b);
    TEST_ASSERT_TRUE(s_fx.spec_count >= 2);

    int at = s_fx.spec_count;
    send_set_spectrum(0, 0, 0); /* disable: other fields ignored */
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_ACK, last_reply_op());
    s_fx.now += 100;
    bridge_poll(&s_b);
    TEST_ASSERT_EQUAL_INT(at, s_fx.spec_count);

    /* Re-enable, then lose the link: the stream must die permanently. */
    send_set_spectrum(1, 64, 30);
    bridge_on_ble_disconnected(&s_b);
    bridge_on_ble_connected(&s_b);
    bridge_on_spectrum_subscribed(&s_b, true); /* CCCD restored (bonded) */
    at = s_fx.spec_count;
    s_fx.now += 100;
    bridge_poll(&s_b);
    TEST_ASSERT_EQUAL_INT(at, s_fx.spec_count); /* starts quiet */
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_valid_bins_and_fps);
    RUN_TEST(test_frag_count_boundaries);
    RUN_TEST(test_frag_build_golden_small_mtu);
    RUN_TEST(test_fullscale_tone_reads_zero_dbfs);
    RUN_TEST(test_negative_frequency_lands_below_centre);
    RUN_TEST(test_dc_offset_is_removed);
    RUN_TEST(test_synth_sweep_is_deterministic_and_visible);
    RUN_TEST(test_set_spectrum_unsupported_without_dsp);
    RUN_TEST(test_set_spectrum_validation);
    RUN_TEST(test_frames_flow_and_seq_increments);
    RUN_TEST(test_disable_and_disconnect_stop_streaming);
    RUN_TEST(test_dropped_frame_leaves_seq_gap_and_no_partial);
    UNITY_END();
    return 0;
}
