/*
 * coalescer — batches radio→BLE bytes into maximal notifications with a
 * bounded latency (docs/implementation.md §4, §5.3).
 *
 * Flush triggers, whichever fires first:
 *   - chunk-full: staged bytes >= max_payload  → emit exactly max_payload
 *   - delimiter:  last staged byte is ';'      → emit everything staged
 *   - idle:       no new bytes for idle_ms     → emit everything staged
 *
 * The caller owns time (pass now_ms in) so tests are deterministic. The
 * coalescer never understands CAT beyond the single ';' delimiter.
 */
#ifndef COALESCER_H
#define COALESCER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COAL_BUF_SIZE 512u /* >= max BLE payload (517-3) we will ever use */
#define COAL_DEFAULT_IDLE_MS 8u
#define COAL_DELIMITER ';'

typedef struct {
    uint8_t buf[COAL_BUF_SIZE];
    size_t len;
    uint32_t last_add_ms;
    uint32_t idle_ms;
} coalescer_t;

void coal_init(coalescer_t *c, uint32_t idle_ms);

/* Stage bytes (drained from the usb→ble ring). Returns bytes accepted; the
 * caller should stop draining the ring when the staging buffer is full and
 * retry after the next flush. */
size_t coal_add(coalescer_t *c, const uint8_t *data, size_t len,
                uint32_t now_ms);

/*
 * If a flush condition holds, returns a pointer to the bytes to emit and sets
 * *out_len (bounded by max_payload); otherwise returns NULL. The caller must
 * call coal_consume(n) after the emission SUCCEEDS — on notify backpressure,
 * skip consume and the same bytes are offered again (§5.1: never drop here).
 */
const uint8_t *coal_poll(coalescer_t *c, uint32_t now_ms, size_t max_payload,
                         size_t *out_len);

void coal_consume(coalescer_t *c, size_t n);

/* Discard everything staged (BLE disconnect / PURGE). */
void coal_reset(coalescer_t *c);

size_t coal_pending(const coalescer_t *c);

#ifdef __cplusplus
}
#endif

#endif /* COALESCER_H */
