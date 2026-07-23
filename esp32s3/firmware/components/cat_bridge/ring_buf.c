#include "ring_buf.h"

#include <string.h>

bool ring_init(ring_buf_t *rb, uint8_t *storage, size_t cap)
{
    if (cap == 0 || (cap & (cap - 1)) != 0 || storage == NULL) {
        return false;
    }
    rb->buf = storage;
    rb->cap = cap;
    rb->mask = cap - 1;
    atomic_store_explicit(&rb->head, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->tail, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->dropped, 0, memory_order_relaxed);
    return true;
}

size_t ring_write(ring_buf_t *rb, const uint8_t *data, size_t len)
{
    size_t head = atomic_load_explicit(&rb->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    size_t free = rb->cap - (head - tail);
    size_t n = len < free ? len : free;

    for (size_t i = 0; i < n; i++) {
        rb->buf[(head + i) & rb->mask] = data[i];
    }
    /* Publish the data before the new head. */
    atomic_store_explicit(&rb->head, head + n, memory_order_release);

    if (n < len) {
        atomic_fetch_add_explicit(&rb->dropped, (uint32_t)(len - n),
                                  memory_order_relaxed);
    }
    return n;
}

size_t ring_read(ring_buf_t *rb, uint8_t *out, size_t max)
{
    size_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    size_t used = head - tail;
    size_t n = max < used ? max : used;

    for (size_t i = 0; i < n; i++) {
        out[i] = rb->buf[(tail + i) & rb->mask];
    }
    atomic_store_explicit(&rb->tail, tail + n, memory_order_release);
    return n;
}

size_t ring_purge(ring_buf_t *rb)
{
    size_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    size_t n = head - tail;
    atomic_store_explicit(&rb->tail, head, memory_order_release);
    return n;
}

size_t ring_used(const ring_buf_t *rb)
{
    size_t head = atomic_load_explicit(&((ring_buf_t *)rb)->head,
                                       memory_order_acquire);
    size_t tail = atomic_load_explicit(&((ring_buf_t *)rb)->tail,
                                       memory_order_acquire);
    return head - tail;
}

size_t ring_free(const ring_buf_t *rb)
{
    return rb->cap - ring_used(rb);
}

uint32_t ring_dropped(const ring_buf_t *rb)
{
    return atomic_load_explicit(&((ring_buf_t *)rb)->dropped,
                                memory_order_relaxed);
}
