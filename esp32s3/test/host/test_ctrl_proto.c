/* Host unit tests for ctrl_proto (docs/implementation.md §7.1). */
#include <string.h>

#include "ctrl_proto.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

/* --- decode ------------------------------------------------------------- */

static void test_decode_empty_returns_minus1(void)
{
    ctrl_frame_t f;
    uint8_t buf[1] = { 0 };
    TEST_ASSERT_EQUAL_INT(-1, ctrl_decode(buf, 0, &f));
}

static void test_decode_incomplete_header(void)
{
    ctrl_frame_t f;
    uint8_t buf[] = { CTRL_OP_GET_STATUS }; /* opcode only, no len byte */
    TEST_ASSERT_EQUAL_INT(0, ctrl_decode(buf, 1, &f));
}

static void test_decode_incomplete_payload(void)
{
    ctrl_frame_t f;
    uint8_t buf[] = { CTRL_OP_SET_BAUD, 4, 0x80, 0x25 }; /* 2 of 4 bytes */
    TEST_ASSERT_EQUAL_INT(0, ctrl_decode(buf, sizeof buf, &f));
}

static void test_decode_zero_len_frame(void)
{
    ctrl_frame_t f;
    uint8_t buf[] = { CTRL_OP_GET_STATUS, 0 };
    TEST_ASSERT_EQUAL_INT(2, ctrl_decode(buf, sizeof buf, &f));
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_GET_STATUS, f.op);
    TEST_ASSERT_EQUAL_UINT8(0, f.len);
    TEST_ASSERT_NULL(f.payload);
}

static void test_decode_max_len_frame(void)
{
    uint8_t buf[CTRL_MAX_FRAME];
    buf[0] = 0x42;
    buf[1] = 255;
    for (int i = 0; i < 255; i++) {
        buf[2 + i] = (uint8_t)i;
    }
    ctrl_frame_t f;
    TEST_ASSERT_EQUAL_INT((int)CTRL_MAX_FRAME,
                          ctrl_decode(buf, sizeof buf, &f));
    TEST_ASSERT_EQUAL_UINT8(255, f.len);
    TEST_ASSERT_EQUAL_UINT8(254, f.payload[254]);
}

static void test_decode_unknown_opcode_still_decodes(void)
{
    /* Dispatch decides how to answer unknown ops — decode must not reject. */
    ctrl_frame_t f;
    uint8_t buf[] = { 0x7F, 1, 0xAA };
    TEST_ASSERT_EQUAL_INT(3, ctrl_decode(buf, sizeof buf, &f));
    TEST_ASSERT_EQUAL_UINT8(0x7F, f.op);
}

/* --- encode + round trip ------------------------------------------------- */

static void test_encode_roundtrip(void)
{
    uint8_t payload[] = { 1, 2, 3, 4, 5 };
    uint8_t wire[CTRL_MAX_FRAME];
    int n = ctrl_encode(CTRL_OP_SET_FAILSAFE, payload, sizeof payload, wire,
                        sizeof wire);
    TEST_ASSERT_EQUAL_INT(7, n);

    ctrl_frame_t f;
    TEST_ASSERT_EQUAL_INT(n, ctrl_decode(wire, (size_t)n, &f));
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_SET_FAILSAFE, f.op);
    TEST_ASSERT_EQUAL_UINT8(sizeof payload, f.len);
    TEST_ASSERT_EQUAL_MEMORY(payload, f.payload, sizeof payload);
}

static void test_encode_capacity_too_small(void)
{
    uint8_t payload[10] = { 0 };
    uint8_t wire[8];
    TEST_ASSERT_EQUAL_INT(-1, ctrl_encode(0x01, payload, sizeof payload, wire,
                                          sizeof wire));
}

static void test_encode_ack_nak(void)
{
    uint8_t wire[8];
    int n = ctrl_encode_ack(CTRL_OP_SET_BAUD, wire, sizeof wire);
    TEST_ASSERT_EQUAL_INT(4, n);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_ACK, wire[0]);
    TEST_ASSERT_EQUAL_UINT8(2, wire[1]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_SET_BAUD, wire[2]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_OK, wire[3]);

    n = ctrl_encode_nak(CTRL_OP_PURGE, CTRL_ERR_BAD_ARG, wire, sizeof wire);
    TEST_ASSERT_EQUAL_INT(4, n);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_NAK, wire[0]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_PURGE, wire[2]);
    TEST_ASSERT_EQUAL_UINT8(CTRL_ERR_BAD_ARG, wire[3]);
}

static void test_encode_evt_overflow_u32le(void)
{
    uint8_t wire[16];
    int n = ctrl_encode_evt_overflow(1, 0x0102A0B0u, wire, sizeof wire);
    TEST_ASSERT_EQUAL_INT(7, n);
    TEST_ASSERT_EQUAL_UINT8(CTRL_OP_EVT_OVERFLOW, wire[0]);
    TEST_ASSERT_EQUAL_UINT8(5, wire[1]);
    TEST_ASSERT_EQUAL_UINT8(1, wire[2]);
    /* little-endian check */
    TEST_ASSERT_EQUAL_UINT8(0xB0, wire[3]);
    TEST_ASSERT_EQUAL_UINT8(0xA0, wire[4]);
    TEST_ASSERT_EQUAL_UINT8(0x02, wire[5]);
    TEST_ASSERT_EQUAL_UINT8(0x01, wire[6]);
}

static void test_u32le_helpers_roundtrip(void)
{
    uint8_t p[4];
    ctrl_put_u32le(p, 38400u);
    TEST_ASSERT_EQUAL_UINT32(38400u, ctrl_get_u32le(p));
    ctrl_put_u32le(p, 0xFFFFFFFFu);
    TEST_ASSERT_EQUAL_UINT32(0xFFFFFFFFu, ctrl_get_u32le(p));
    ctrl_put_u32le(p, 0);
    TEST_ASSERT_EQUAL_UINT32(0, ctrl_get_u32le(p));
}

/* --- STATUS struct -------------------------------------------------------- */

static void test_status_roundtrip(void)
{
    ctrl_status_t s = {
        .usb_state = CTRL_USB_ENUMERATED,
        .radio_id = CTRL_RADIO_FT891,
        .baud = 38400,
        .drops_usb_to_ble = 17,
        .drops_ble_to_usb = 3,
        .fw_major = 1,
        .fw_minor = 4,
        .reset_reason = 2,
        .min_free_heap = 123456,
    };
    uint8_t wire[CTRL_STATUS_SIZE];
    TEST_ASSERT_EQUAL_INT((int)CTRL_STATUS_SIZE,
                          ctrl_status_encode(&s, wire, sizeof wire));
    TEST_ASSERT_EQUAL_UINT8(CTRL_STATUS_FMT_VERSION, wire[0]);

    ctrl_status_t d;
    TEST_ASSERT_EQUAL_INT(0, ctrl_status_decode(wire, sizeof wire, &d));
    TEST_ASSERT_EQUAL_UINT8(s.usb_state, d.usb_state);
    TEST_ASSERT_EQUAL_UINT8(s.radio_id, d.radio_id);
    TEST_ASSERT_EQUAL_UINT32(s.baud, d.baud);
    TEST_ASSERT_EQUAL_UINT32(s.drops_usb_to_ble, d.drops_usb_to_ble);
    TEST_ASSERT_EQUAL_UINT32(s.drops_ble_to_usb, d.drops_ble_to_usb);
    TEST_ASSERT_EQUAL_UINT8(s.fw_major, d.fw_major);
    TEST_ASSERT_EQUAL_UINT8(s.fw_minor, d.fw_minor);
    TEST_ASSERT_EQUAL_UINT8(s.reset_reason, d.reset_reason);
    TEST_ASSERT_EQUAL_UINT32(s.min_free_heap, d.min_free_heap);
}

static void test_status_decode_rejects_short_and_bad_version(void)
{
    uint8_t wire[CTRL_STATUS_SIZE] = { 0 };
    ctrl_status_t d;
    TEST_ASSERT_EQUAL_INT(-1, ctrl_status_decode(wire, 5, &d));
    wire[0] = 99; /* wrong version */
    TEST_ASSERT_EQUAL_INT(-1, ctrl_status_decode(wire, sizeof wire, &d));
}

static void test_status_encode_short_buffer(void)
{
    ctrl_status_t s = { 0 };
    uint8_t wire[CTRL_STATUS_SIZE - 1];
    TEST_ASSERT_EQUAL_INT(-1, ctrl_status_encode(&s, wire, sizeof wire));
}

/* --- fuzz-ish: decode never reads out of bounds --------------------------- */

static void test_decode_garbage_sweep(void)
{
    /* Every (opcode,len) pair against every buffer size: decode must return
     * a value consistent with the framing rule and never crash (ASan-guarded
     * in the host build). */
    uint8_t buf[64];
    for (int op = 0; op < 256; op += 7) {
        for (int len = 0; len < 256; len += 11) {
            buf[0] = (uint8_t)op;
            buf[1] = (uint8_t)len;
            for (size_t n = 0; n <= sizeof buf; n++) {
                ctrl_frame_t f;
                int r = ctrl_decode(buf, n, &f);
                if (n == 0) {
                    TEST_ASSERT_EQUAL_INT(-1, r);
                } else if (n < 2u + (unsigned)len) {
                    TEST_ASSERT_EQUAL_INT(0, r);
                } else {
                    TEST_ASSERT_EQUAL_INT(2 + len, r);
                }
            }
        }
    }
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_decode_empty_returns_minus1);
    RUN_TEST(test_decode_incomplete_header);
    RUN_TEST(test_decode_incomplete_payload);
    RUN_TEST(test_decode_zero_len_frame);
    RUN_TEST(test_decode_max_len_frame);
    RUN_TEST(test_decode_unknown_opcode_still_decodes);
    RUN_TEST(test_encode_roundtrip);
    RUN_TEST(test_encode_capacity_too_small);
    RUN_TEST(test_encode_ack_nak);
    RUN_TEST(test_encode_evt_overflow_u32le);
    RUN_TEST(test_u32le_helpers_roundtrip);
    RUN_TEST(test_status_roundtrip);
    RUN_TEST(test_status_decode_rejects_short_and_bad_version);
    RUN_TEST(test_status_encode_short_buffer);
    RUN_TEST(test_decode_garbage_sweep);
    return UNITY_END();
}
