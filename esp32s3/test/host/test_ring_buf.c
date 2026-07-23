/* Host unit tests for ring_buf (docs/implementation.md §7.1). */
#include <pthread.h>
#include <string.h>

#include "ring_buf.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

static void test_init_rejects_bad_capacity(void)
{
    ring_buf_t rb;
    uint8_t st[8];
    TEST_ASSERT_FALSE(ring_init(&rb, st, 0));
    TEST_ASSERT_FALSE(ring_init(&rb, st, 6)); /* not a power of two */
    TEST_ASSERT_FALSE(ring_init(&rb, NULL, 8));
    TEST_ASSERT_TRUE(ring_init(&rb, st, 8));
}

static void test_simple_write_read(void)
{
    ring_buf_t rb;
    uint8_t st[16], out[16];
    ring_init(&rb, st, sizeof st);

    TEST_ASSERT_EQUAL_size_t(5, ring_write(&rb, (const uint8_t *)"hello", 5));
    TEST_ASSERT_EQUAL_size_t(5, ring_used(&rb));
    TEST_ASSERT_EQUAL_size_t(11, ring_free(&rb));
    TEST_ASSERT_EQUAL_size_t(5, ring_read(&rb, out, sizeof out));
    TEST_ASSERT_EQUAL_MEMORY("hello", out, 5);
    TEST_ASSERT_EQUAL_size_t(0, ring_used(&rb));
}

static void test_wraparound(void)
{
    ring_buf_t rb;
    uint8_t st[8], out[8];
    ring_init(&rb, st, sizeof st);

    /* Push the indices around the ring many times. */
    for (int i = 0; i < 100; i++) {
        uint8_t v[3] = { (uint8_t)i, (uint8_t)(i + 1), (uint8_t)(i + 2) };
        TEST_ASSERT_EQUAL_size_t(3, ring_write(&rb, v, 3));
        TEST_ASSERT_EQUAL_size_t(3, ring_read(&rb, out, 3));
        TEST_ASSERT_EQUAL_MEMORY(v, out, 3);
    }
    TEST_ASSERT_EQUAL_UINT32(0, ring_dropped(&rb));
}

static void test_overflow_drops_newest_and_counts(void)
{
    ring_buf_t rb;
    uint8_t st[8], out[8];
    ring_init(&rb, st, sizeof st);

    uint8_t data[12];
    for (int i = 0; i < 12; i++) {
        data[i] = (uint8_t)i;
    }
    /* Capacity 8: 8 written, 4 dropped (the NEWEST 4). */
    TEST_ASSERT_EQUAL_size_t(8, ring_write(&rb, data, 12));
    TEST_ASSERT_EQUAL_UINT32(4, ring_dropped(&rb));
    TEST_ASSERT_EQUAL_size_t(8, ring_read(&rb, out, 8));
    for (int i = 0; i < 8; i++) {
        TEST_ASSERT_EQUAL_UINT8(i, out[i]); /* oldest survived */
    }

    /* Full ring: everything dropped. */
    ring_write(&rb, data, 8);
    TEST_ASSERT_EQUAL_size_t(0, ring_write(&rb, data, 5));
    TEST_ASSERT_EQUAL_UINT32(9, ring_dropped(&rb));
}

static void test_purge(void)
{
    ring_buf_t rb;
    uint8_t st[16];
    ring_init(&rb, st, sizeof st);
    ring_write(&rb, (const uint8_t *)"0123456789", 10);
    TEST_ASSERT_EQUAL_size_t(10, ring_purge(&rb));
    TEST_ASSERT_EQUAL_size_t(0, ring_used(&rb));
    TEST_ASSERT_EQUAL_size_t(16, ring_free(&rb));
    /* Ring still usable after purge. */
    uint8_t out[4];
    ring_write(&rb, (const uint8_t *)"abcd", 4);
    TEST_ASSERT_EQUAL_size_t(4, ring_read(&rb, out, 4));
    TEST_ASSERT_EQUAL_MEMORY("abcd", out, 4);
}

static void test_read_partial(void)
{
    ring_buf_t rb;
    uint8_t st[16], out[4];
    ring_init(&rb, st, sizeof st);
    ring_write(&rb, (const uint8_t *)"abcdefgh", 8);
    TEST_ASSERT_EQUAL_size_t(4, ring_read(&rb, out, 4));
    TEST_ASSERT_EQUAL_MEMORY("abcd", out, 4);
    TEST_ASSERT_EQUAL_size_t(4, ring_read(&rb, out, 4));
    TEST_ASSERT_EQUAL_MEMORY("efgh", out, 4);
}

/* --- concurrency: one producer thread + one consumer thread --------------- */

#define STRESS_BYTES (1u << 20) /* 1 MiB through a 256-byte ring */

typedef struct {
    ring_buf_t *rb;
    uint32_t produced;
} producer_arg_t;

static void *producer_fn(void *argp)
{
    producer_arg_t *a = argp;
    uint8_t seq = 0;
    uint32_t sent = 0;
    while (sent < STRESS_BYTES) {
        uint8_t burst[37];
        size_t n = sizeof burst;
        if (STRESS_BYTES - sent < n) {
            n = STRESS_BYTES - sent;
        }
        for (size_t i = 0; i < n; i++) {
            burst[i] = seq++;
        }
        size_t w = ring_write(a->rb, burst, n);
        if (w < n) {
            /* Sequence integrity requires no drops in this test: rewind. */
            seq = (uint8_t)(seq - (n - w));
        }
        sent += (uint32_t)w;
    }
    a->produced = sent;
    return NULL;
}

static void test_spsc_threaded_stress(void)
{
    ring_buf_t rb;
    static uint8_t st[256];
    ring_init(&rb, st, sizeof st);

    producer_arg_t arg = { .rb = &rb, .produced = 0 };
    pthread_t th;
    TEST_ASSERT_EQUAL_INT(0, pthread_create(&th, NULL, producer_fn, &arg));

    uint8_t expect = 0;
    uint32_t got = 0;
    while (got < STRESS_BYTES) {
        uint8_t out[64];
        size_t n = ring_read(&rb, out, sizeof out);
        for (size_t i = 0; i < n; i++) {
            if (out[i] != expect) {
                pthread_join(th, NULL);
                TEST_FAIL_MESSAGE("sequence corruption in SPSC stress");
            }
            expect++;
        }
        got += (uint32_t)n;
    }
    pthread_join(th, NULL);
    TEST_ASSERT_EQUAL_UINT32(STRESS_BYTES, got);
    TEST_ASSERT_EQUAL_UINT32(STRESS_BYTES, arg.produced);
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_init_rejects_bad_capacity);
    RUN_TEST(test_simple_write_read);
    RUN_TEST(test_wraparound);
    RUN_TEST(test_overflow_drops_newest_and_counts);
    RUN_TEST(test_purge);
    RUN_TEST(test_read_partial);
    RUN_TEST(test_spsc_threaded_stress);
    return UNITY_END();
}
