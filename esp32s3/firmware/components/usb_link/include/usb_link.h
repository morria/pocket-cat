/*
 * usb_link — ESP-IDF glue between the USB host stack and bridge_core
 * (docs/implementation.md §5.1/§5.2, references/firmware-esp-idf-usb-host-vcp.md).
 *
 * Owns: usb_host library install + daemon task, CDC-ACM host driver,
 * per-interface radio detection, device open/close lifecycle, and the
 * CP210x vendor-request setup (AN571) for SiLabs bridges.
 */
#ifndef USB_LINK_H
#define USB_LINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bridge_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Start the USB host stack and begin waiting for a radio. The bridge's
 * usb-facing ops (usb_tx/set_baud/set_line/usb_reset) must point at the
 * usb_link_op_* functions below before the first device attaches. */
esp_err_t usb_link_start(bridge_t *bridge);

/* bridge_ops_t implementations (ctx = bridge_t*). */
int usb_link_op_tx(void *ctx, const uint8_t *data, size_t len);
int usb_link_op_set_baud(void *ctx, uint32_t baud);
int usb_link_op_set_line(void *ctx, bool dtr, bool rts);
int usb_link_op_reset(void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* USB_LINK_H */
