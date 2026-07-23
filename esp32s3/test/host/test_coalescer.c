/* Host unit tests for the notification coalescer (docs/implementation.md §7.1):
 * scripted byte-arrival timelines → assert flush boundaries (';', MTU-full,
 * idle timer) and the max-latency bound. */
#include <string.h>

#include "coalescer.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

#define MTU_PAYLOAD 182u /* iOS-typical 185 − 3 */

static void test_no_data_no_flush(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    size_t n;
    TEST_ASSERT_NULL(coal_poll(&c, 1000, MTU_PAYLOAD, &n));
}

static void test_delimiter_flushes_immediately(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"FA014250000;", 12, 100);
    size_t n = 0;
    const uint8_t *p = coal_poll(&c, 100, MTU_PAYLOAD, &n); /* same ms: no idle */
    TEST_ASSERT_NOT_NULL(p);
    TEST_ASSERT_EQUAL_size_t(12, n);
    TEST_ASSERT_EQUAL_MEMORY("FA014250000;", p, 12);
    coal_consume(&c, n);
    TEST_ASSERT_EQUAL_size_t(0, coal_pending(&c));
}

static void test_partial_waits_then_idle_flushes(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"FA0142", 6, 100); /* no ';' yet */
    size_t n;
    TEST_ASSERT_NULL(coal_poll(&c, 104, MTU_PAYLOAD, &n)); /* 4 ms: hold */
    TEST_ASSERT_NULL(coal_poll(&c, 107, MTU_PAYLOAD, &n)); /* 7 ms: hold */
    const uint8_t *p = coal_poll(&c, 108, MTU_PAYLOAD, &n); /* 8 ms: flush */
    TEST_ASSERT_NOT_NULL(p);
    TEST_ASSERT_EQUAL_size_t(6, n);
}

static void test_new_bytes_reset_idle_timer(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"AB", 2, 100);
    coal_add(&c, (const uint8_t *)"CD", 2, 106); /* refresh at t=106 */
    size_t n;
    TEST_ASSERT_NULL(coal_poll(&c, 110, MTU_PAYLOAD, &n)); /* 4 ms since add */
    TEST_ASSERT_NOT_NULL(coal_poll(&c, 114, MTU_PAYLOAD, &n));
    TEST_ASSERT_EQUAL_size_t(4, n);
}

static void test_mtu_full_emits_exact_chunk_and_keeps_rest(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    uint8_t big[300];
    for (size_t i = 0; i < sizeof big; i++) {
        big[i] = (uint8_t)('A' + (i % 26));
    }
    coal_add(&c, big, sizeof big, 50);

    size_t n;
    const uint8_t *p = coal_poll(&c, 50, MTU_PAYLOAD, &n);
    TEST_ASSERT_NOT_NULL(p);
    TEST_ASSERT_EQUAL_size_t(MTU_PAYLOAD, n); /* exactly one maximal chunk */
    TEST_ASSERT_EQUAL_MEMORY(big, p, MTU_PAYLOAD);
    coal_consume(&c, n);

    /* Remainder: 300-182=118, no ';', not full → waits for idle. */
    TEST_ASSERT_NULL(coal_poll(&c, 51, MTU_PAYLOAD, &n));
    p = coal_poll(&c, 58, MTU_PAYLOAD, &n);
    TEST_ASSERT_NOT_NULL(p);
    TEST_ASSERT_EQUAL_size_t(118, n);
    TEST_ASSERT_EQUAL_MEMORY(&big[MTU_PAYLOAD], p, 118);
}

static void test_chunk_boundaries_around_mtu(void)
{
    /* §7.3 chunking: length 1, MTU−1, MTU, MTU+1, 3×MTU+1. */
    /* Sizes deliberately straddle both the MTU and COAL_BUF_SIZE: the
     * largest (3×MTU+1 = 547) exceeds the 512-byte staging buffer, so the
     * feed loop below mirrors the bridge task: re-add remaining bytes as
     * emission frees space (bridge_core's pump_usb_to_ble drain loop). */
    static const size_t sizes[] = { 1, MTU_PAYLOAD - 1, MTU_PAYLOAD,
                                    MTU_PAYLOAD + 1, 3 * MTU_PAYLOAD + 1 };
    for (size_t si = 0; si < sizeof sizes / sizeof sizes[0]; si++) {
        coalescer_t c;
        coal_init(&c, 8);
        size_t len = sizes[si];
        uint8_t data[3 * MTU_PAYLOAD + 2];
        for (size_t i = 0; i < len; i++) {
            data[i] = (uint8_t)i;
        }
        data[len - 1] = ';'; /* complete CAT response */

        size_t added = 0, emitted = 0;
        uint32_t now = 10;
        while (emitted < len) {
            added += coal_add(&c, &data[added], len - added, now);
            size_t n;
            const uint8_t *p = coal_poll(&c, now, MTU_PAYLOAD, &n);
            TEST_ASSERT_NOT_NULL_MESSAGE(p, "expected flush");
            TEST_ASSERT_TRUE(n <= MTU_PAYLOAD);
            TEST_ASSERT_EQUAL_MEMORY(&data[emitted], p, n);
            coal_consume(&c, n);
            emitted += n;
        }
        TEST_ASSERT_EQUAL_size_t(len, added);
        TEST_ASSERT_EQUAL_size_t(len, emitted);
        TEST_ASSERT_EQUAL_size_t(0, coal_pending(&c));
    }
}

static void test_backpressure_reoffers_same_bytes(void)
{
    /* §5.1: on notify failure the caller skips consume; the next poll must
     * offer identical bytes. */
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"ID0650;", 7, 5);
    size_t n1, n2;
    const uint8_t *p1 = coal_poll(&c, 5, MTU_PAYLOAD, &n1);
    TEST_ASSERT_NOT_NULL(p1);
    /* no consume — simulate BLE_HS_ENOMEM */
    const uint8_t *p2 = coal_poll(&c, 6, MTU_PAYLOAD, &n2);
    TEST_ASSERT_EQUAL_PTR(p1, p2);
    TEST_ASSERT_EQUAL_size_t(n1, n2);
}

static void test_reset_discards(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"junk", 4, 5);
    coal_reset(&c);
    size_t n;
    TEST_ASSERT_NULL(coal_poll(&c, 100, MTU_PAYLOAD, &n));
}

static void test_add_respects_capacity(void)
{
    coalescer_t c;
    coal_init(&c, 8);
    uint8_t big[COAL_BUF_SIZE + 100];
    memset(big, 'x', sizeof big);
    size_t accepted = coal_add(&c, big, sizeof big, 1);
    TEST_ASSERT_EQUAL_size_t(COAL_BUF_SIZE, accepted);
    TEST_ASSERT_EQUAL_size_t(COAL_BUF_SIZE, coal_pending(&c));
    /* Zero space: nothing accepted, caller keeps bytes in the ring. */
    TEST_ASSERT_EQUAL_size_t(0, coal_add(&c, big, 10, 2));
}

static void test_time_wraparound(void)
{
    /* now_ms wraps at 2^32 (49.7 days): the idle comparison must survive. */
    coalescer_t c;
    coal_init(&c, 8);
    coal_add(&c, (const uint8_t *)"AB", 2, 0xFFFFFFFCu);
    size_t n;
    TEST_ASSERT_NULL(coal_poll(&c, 0xFFFFFFFEu, MTU_PAYLOAD, &n)); /* +2 ms */
    TEST_ASSERT_NOT_NULL(coal_poll(&c, 4u, MTU_PAYLOAD, &n)); /* +8 ms wrapped */
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_no_data_no_flush);
    RUN_TEST(test_delimiter_flushes_immediately);
    RUN_TEST(test_partial_waits_then_idle_flushes);
    RUN_TEST(test_new_bytes_reset_idle_timer);
    RUN_TEST(test_mtu_full_emits_exact_chunk_and_keeps_rest);
    RUN_TEST(test_chunk_boundaries_around_mtu);
    RUN_TEST(test_backpressure_reoffers_same_bytes);
    RUN_TEST(test_reset_discards);
    RUN_TEST(test_add_respects_capacity);
    RUN_TEST(test_time_wraparound);
    return UNITY_END();
}
