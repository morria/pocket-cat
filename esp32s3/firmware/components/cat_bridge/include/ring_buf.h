/*
 * ring_buf — lock-free single-producer/single-consumer byte ring buffer.
 *
 * Overflow policy (docs/implementation.md §5.4): drop-NEWEST. A write that
 * does not fully fit writes what fits and counts the rest in `dropped`.
 * The producer and consumer must each be a single context (task or callback);
 * `purge` is consumer-side only.
 *
 * Pure C11 (stdatomic); host-testable. Capacity must be a power of two.
 */
#ifndef RING_BUF_H
#define RING_BUF_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *buf;
    size_t cap;            /* power of two */
    size_t mask;
    _Atomic size_t head;   /* write index (producer)  */
    _Atomic size_t tail;   /* read index  (consumer)  */
    _Atomic uint32_t dropped; /* lifetime dropped bytes  */
} ring_buf_t;

/* Returns false if cap is 0 or not a power of two. */
bool ring_init(ring_buf_t *rb, uint8_t *storage, size_t cap);

/* Producer side. Returns bytes actually written; the shortfall is added to
 * `dropped`. Never blocks. */
size_t ring_write(ring_buf_t *rb, const uint8_t *data, size_t len);

/* Consumer side. Returns bytes copied out (<= max). Never blocks. */
size_t ring_read(ring_buf_t *rb, uint8_t *out, size_t max);

/* Consumer side: discard everything currently readable. Returns bytes
 * discarded. */
size_t ring_purge(ring_buf_t *rb);

size_t ring_used(const ring_buf_t *rb);
size_t ring_free(const ring_buf_t *rb);
uint32_t ring_dropped(const ring_buf_t *rb);

#ifdef __cplusplus
}
#endif

#endif /* RING_BUF_H */
