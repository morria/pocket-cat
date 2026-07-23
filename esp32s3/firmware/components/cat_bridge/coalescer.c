#include "coalescer.h"

#include <string.h>

void coal_init(coalescer_t *c, uint32_t idle_ms)
{
    c->len = 0;
    c->last_add_ms = 0;
    c->idle_ms = idle_ms ? idle_ms : COAL_DEFAULT_IDLE_MS;
}

size_t coal_add(coalescer_t *c, const uint8_t *data, size_t len,
                uint32_t now_ms)
{
    size_t space = COAL_BUF_SIZE - c->len;
    size_t n = len < space ? len : space;
    if (n) {
        memcpy(&c->buf[c->len], data, n);
        c->len += n;
        c->last_add_ms = now_ms;
    }
    return n;
}

const uint8_t *coal_poll(coalescer_t *c, uint32_t now_ms, size_t max_payload,
                         size_t *out_len)
{
    if (c->len == 0 || max_payload == 0) {
        return NULL;
    }
    if (c->len >= max_payload) {
        *out_len = max_payload; /* chunk-full: emit one maximal notification */
        return c->buf;
    }
    if (c->buf[c->len - 1] == COAL_DELIMITER) {
        *out_len = c->len; /* delimiter: a CAT response just completed */
        return c->buf;
    }
    if ((uint32_t)(now_ms - c->last_add_ms) >= c->idle_ms) {
        *out_len = c->len; /* idle: bound the latency of partial data */
        return c->buf;
    }
    return NULL;
}

void coal_consume(coalescer_t *c, size_t n)
{
    if (n >= c->len) {
        c->len = 0;
        return;
    }
    memmove(c->buf, &c->buf[n], c->len - n);
    c->len -= n;
}

void coal_reset(coalescer_t *c)
{
    c->len = 0;
}

size_t coal_pending(const coalescer_t *c)
{
    return c->len;
}
