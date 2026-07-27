/*
 * ble_link — NimBLE peripheral glue for the CAT bridge
 * (docs/implementation.md §4, references/firmware-nimble-ble.md).
 *
 * GATT: one primary service with CAT_RX (write), CAT_TX (notify),
 * CTRL (write+notify), STATUS (read+notify). UUIDs match test/tools/catproto.py.
 */
#ifndef BLE_LINK_H
#define BLE_LINK_H

#include <stddef.h>
#include <stdint.h>

#include "bridge_core.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Start NimBLE, register the GATT table, begin advertising. */
esp_err_t ble_link_start(bridge_t *bridge);

/* bridge_ops_t implementations (ctx = bridge_t*). Non-zero return means
 * backpressure/no-subscriber; the bridge retries CAT bytes (§5.1). */
int ble_link_op_notify_cat(void *ctx, const uint8_t *data, size_t len);
int ble_link_op_notify_ctrl(void *ctx, const uint8_t *data, size_t len);
int ble_link_op_notify_status(void *ctx, const uint8_t *data, size_t len);
int ble_link_op_notify_spectrum(void *ctx, const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* BLE_LINK_H */
